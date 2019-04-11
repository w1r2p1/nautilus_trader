#!/usr/bin/env python3
# -------------------------------------------------------------------------------------------------
# <copyright file="engine.pyx" company="Invariance Pte">
#  Copyright (C) 2018-2019 Invariance Pte. All rights reserved.
#  The use of this source code is governed by the license as found in the LICENSE.md file.
#  http://www.invariance.com
# </copyright>
# -------------------------------------------------------------------------------------------------

# cython: language_level=3, boundscheck=False, wraparound=False, nonecheck=False

import cython
import numpy as np
import scipy
import pandas as pd
import logging
import psutil
import platform
import empyrical
import pymc3

from platform import python_version
from cpython.datetime cimport datetime, timedelta
from pandas import DataFrame
from typing import List, Dict
from logging import INFO, DEBUG

from inv_trader.version import __version__
from inv_trader.core.precondition cimport Precondition
from inv_trader.core.functions cimport format_zulu_datetime
from inv_trader.backtest.data cimport BacktestDataClient
from inv_trader.backtest.execution cimport BacktestExecClient
from inv_trader.common.brokerage import CommissionCalculator
from inv_trader.common.clock cimport LiveClock, TestClock
from inv_trader.common.guid cimport TestGuidFactory
from inv_trader.common.logger cimport TestLogger
from inv_trader.enums.currency cimport Currency, currency_string
from inv_trader.enums.resolution cimport Resolution
from inv_trader.common.account cimport Account
from inv_trader.model.objects cimport Symbol, Instrument, Money
from inv_trader.portfolio.portfolio cimport Portfolio
from inv_trader.strategy cimport TradeStrategy


cdef class BacktestConfig:
    """
    Represents a configuration for a BacktestEngine.
    """
    def __init__(self,
                 int starting_capital=1000000,
                 Currency account_currency=Currency.USD,
                 int slippage_ticks=0,
                 float commission_rate_bp=0.20,
                 bint bypass_logging=False,
                 level_console: logging=INFO,
                 level_file: logging=DEBUG,
                 bint console_prints=True,
                 bint log_thread=False,
                 bint log_to_file=False,
                 str log_file_path='backtests/'):
        """
        Initializes a new instance of the BacktestEngine class.

        :param starting_capital: The starting account capital (> 0).
        :param account_currency: The currency for the account.
        :param slippage_ticks: The slippage ticks per transaction (>= 0).
        :param commission_rate_bp: The commission rate in basis points per notional transaction size.
        :param bypass_logging: The flag indicating whether logging should be bypassed.
        :param level_console: The minimum log level for logging messages to the console.
        :param level_file: The minimum log level for logging messages to the log file.
        :param console_prints: The boolean flag indicating whether log messages should print.
        :param log_thread: The boolean flag indicating whether log messages should log the thread.
        :param log_to_file: The boolean flag indicating whether log messages should log to file.
        :param log_file_path: The name of the log file (cannot be None if log_to_file is True).
        :raises ValueError: If the starting capital is not positive (> 0).
        :raises ValueError: If the leverage is not positive (> 0).
        :raises ValueError: If the slippage_ticks is negative (< 0).
        :raises ValueError: If the commission_rate is not of type Decimal.
        :raises ValueError: If the commission_rate is negative (< 0).
        """
        Precondition.positive(starting_capital, 'starting_capital')
        Precondition.not_negative(slippage_ticks, 'slippage_ticks')
        Precondition.not_negative(commission_rate_bp, 'commission_rate_bp')

        self.starting_capital = Money(starting_capital)
        self.account_currency = account_currency
        self.slippage_ticks = slippage_ticks
        self.commission_rate_bp = commission_rate_bp
        self.bypass_logging = bypass_logging
        self.level_console = level_console
        self.level_file = level_file
        self.console_prints = console_prints
        self.log_thread = log_thread
        self.log_to_file = log_to_file
        self.log_file_path = log_file_path


cdef class MarketModel:
    """
    Represents the parameters for market dynamics including probabilistic modeling
    of order fill and slippage behaviour by order type.
    """

    def __init__(self,
                 float prob_fill_limit_best=0.2,
                 float prob_fill_limit_mid=0.5,
                 float prob_fill_limit_cross=0.8,
                 float prob_fill_stop=0.95,
                 float prob_slippage=0.0):
        """
        Initializes a new instance of the MarketModel class.

        Fill Modelling
        --------------
         BUY-LIMIT fill price 'best'  = BID.
         BUY-LIMIT fill price 'mid'   = MID.
         BUY-LIMIT fill price 'cross' = ASK.
        SELL-LIMIT fill price 'best'  = ASK.
        SELL-LIMIT fill price 'mid'   = MID.
        SELL-LIMIT fill price 'cross' = BID.

        :param prob_fill_limit_best: The probability of working limit orders filling at the best price.
        :param prob_fill_limit_mid: The probability of working limit orders filling at the mid price.
        :param prob_fill_limit_cross: The probability of working limit orders filling at the spread crossing price.
        :param prob_fill_stop: The probability of working stop orders filling at their price.
        :param prob_slippage: The probability of order fill prices slipping by a tick.
        :raises ValueError: If any probability argument is not within range [0, 1].
        """
        Precondition.in_range(prob_fill_limit_best, 'prob_fill_limit_best', 0.0, 1.0)
        Precondition.in_range(prob_fill_limit_mid, 'prob_fill_limit_mid', 0.0, 1.0)
        Precondition.in_range(prob_fill_limit_cross, 'prob_fill_limit_cross', 0.0, 1.0)
        Precondition.in_range(prob_fill_stop, 'prob_fill_stop', 0.0, 1.0)
        Precondition.in_range(prob_slippage, 'prob_slippage', 0.0, 1.0)

        self.prob_fill_limit_best = prob_fill_limit_best
        self.prob_fill_limit_mid = prob_fill_limit_mid
        self.prob_fill_limit_cross = prob_fill_limit_cross
        self.prob_fill_stop = prob_fill_stop
        self.prob_slippage = prob_slippage


cdef class BacktestEngine:
    """
    Provides a backtest engine to run a portfolio of strategies inside a Trader
    on historical data.
    """

    def __init__(self,
                 list instruments: List[Instrument],
                 dict data_ticks: Dict[Symbol, DataFrame],
                 dict data_bars_bid: Dict[Symbol, Dict[Resolution, DataFrame]],
                 dict data_bars_ask: Dict[Symbol, Dict[Resolution, DataFrame]],
                 list strategies: List[TradeStrategy],
                 BacktestConfig config=BacktestConfig()):
        """
        Initializes a new instance of the BacktestEngine class.

        :param strategies: The strategies to backtest.
        :param data_bars_bid: The historical bid market data needed for the backtest.
        :param data_bars_ask: The historical ask market data needed for the backtest.
        :param strategies: The strategies for the backtest.
        :param config: The configuration for the backtest.
        :raises ValueError: If the instruments list contains a type other than Instrument.
        :raises ValueError: If the strategies list contains a type other than TradeStrategy.
        """
        Precondition.list_type(instruments, Instrument, 'instruments')
        Precondition.list_type(strategies, TradeStrategy, 'strategies')
        # Data checked in BacktestDataClient

        self.config = config
        self.clock = LiveClock()
        self.created_time = self.clock.time_now()

        self.test_clock = TestClock()
        self.test_clock.set_time(self.clock.time_now())
        self.test_logger = TestLogger(
            name='backtest',
            bypass_logging=config.bypass_logging,
            level_console=config.level_console,
            level_file=config.level_file,
            console_prints=config.console_prints,
            log_thread=config.log_thread,
            log_to_file=config.log_to_file,
            log_file_path=config.log_file_path,
            clock=self.test_clock)
        self.log = LoggerAdapter(component_name='BacktestEngine', logger=self.test_logger)

        self._engine_header()

        self.account = Account(currency=config.account_currency)
        self.portfolio = Portfolio(
            clock=self.test_clock,
            guid_factory=TestGuidFactory(),
            logger=self.test_logger)
        self.instruments = instruments
        self.data_client = BacktestDataClient(
            instruments=instruments,
            data_ticks=data_ticks,
            data_bars_bid=data_bars_bid,
            data_bars_ask=data_bars_ask,
            clock=self.test_clock,
            logger=self.test_logger)

        cdef dict minute_bars_bid = {}
        for symbol, data in data_bars_bid.items():
            minute_bars_bid[symbol] = data[Resolution.MINUTE]

        cdef dict minute_bars_ask = {}
        for symbol, data in data_bars_ask.items():
            minute_bars_ask[symbol] = data[Resolution.MINUTE]

        self.exec_client = BacktestExecClient(
            instruments=instruments,
            data_ticks=data_ticks,
            data_bars_bid=minute_bars_bid,
            data_bars_ask=minute_bars_ask,
            starting_capital=config.starting_capital,
            slippage_ticks=config.slippage_ticks,
            commission_calculator=CommissionCalculator(default_rate_bp=config.commission_rate_bp),
            account=self.account,
            portfolio=self.portfolio,
            clock=self.test_clock,
            guid_factory=TestGuidFactory(),
            logger=self.test_logger)

        self.data_minute_index = self.data_client.data_minute_index

        assert(all(self.data_minute_index) == all(self.data_client.data_minute_index))
        assert(all(self.data_minute_index) == all(self.exec_client.data_minute_index))

        for strategy in strategies:
            # Replace strategies clocks with test clocks
            strategy.change_clock(TestClock())  # Separate test clock to iterate independently
            # Replace strategies loggers with test loggers
            strategy.change_logger(self.test_logger)

        self.trader = Trader(
            'Backtest',
            strategies,
            self.data_client,
            self.exec_client,
            self.account,
            self.portfolio,
            self.test_clock,
            self.test_logger)

        self.time_to_initialize = self.clock.get_elapsed(self.created_time)
        self.log.info(f'Initialized in {round(self.time_to_initialize, 2)}s.')

    cpdef void run(
            self,
            datetime start,
            datetime stop,
            int time_step_mins=1):
        """
        Run the backtest.
        
        :param start: The start time for the backtest (must be >= first_timestamp and < stop).
        :param stop: The stop time for the backtest (must be <= last_timestamp and > start).
        :param time_step_mins: The time step in minutes for each test clock iterations (> 0)
        
        Note: The default time_step_mins is 1 and shouldn't need to be changed.
        :raises: ValueError: If the start datetime is not < the stop datetime.
        :raises: ValueError: If the start datetime is not >= the first index timestamp of data.
        :raises: ValueError: If the start datetime is not <= the last index timestamp of data.
        :raises: ValueError: If the time_step_mins is not positive (> 0).
        """
        Precondition.true(start < stop, 'start < stop')
        Precondition.true(start >= self.data_minute_index[0], 'start >= first_timestamp')
        Precondition.true(stop <= self.data_minute_index[len(self.data_minute_index) - 1], 'stop <= last_timestamp')
        Precondition.positive(time_step_mins, 'time_step_mins')

        cdef timedelta time_step = timedelta(minutes=time_step_mins)
        cdef datetime run_started = self.clock.time_now()
        cdef datetime time = start

        self._backtest_header(run_started, start, stop, time_step_mins)
        self.test_clock.set_time(time)

        self._change_strategy_clocks_and_loggers(self.trader.strategies)
        self.trader.start()

        self.log.debug("Setting initial iterations...")
        self.data_client.set_initial_iteration(start, time_step)  # Also sets clock to start time
        self.exec_client.set_initial_iteration(start, time_step)  # Also sets clock to start time

        assert(self.data_client.iteration == self.exec_client.iteration)
        assert(self.data_client.time_now() == start)
        assert(self.exec_client.time_now() == start)

        self.log.info(f"Running backtest...")
        while time <= stop:
            self.test_clock.set_time(time)
            self.exec_client.process_market()
            self.data_client.iterate()
            self.exec_client.iterate()
            for strategy in self.trader.strategies:
                strategy.iterate(time)
            time += time_step

        self.log.info("Stopping...")
        self.trader.stop()
        self._backtest_footer(run_started, start, stop)
        self.log.info("Stopped.")

    cpdef void change_strategies(self, list strategies: List[TradeStrategy]):
        """
        Change strategies with the given list of trade strategies.
        
        :param strategies: The list of strategies to load into the engine.
        :raises ValueError: If the strategies list contains a type other than TradeStrategy.
        """
        Precondition.list_type(strategies, TradeStrategy, 'strategies')

        self._change_strategy_clocks_and_loggers(strategies)
        self.trader.change_strategies(strategies)

    cpdef void create_returns_tear_sheet(self):
        """
        Create a pyfolio returns tear sheet based on analyzer data from the last run.
        """
        self.trader.create_returns_tear_sheet()

    cpdef void create_full_tear_sheet(self):
        """
        Create a pyfolio full tear sheet based on analyzer data from the last run.
        """
        self.trader.create_full_tear_sheet()

    cpdef dict get_performance_stats(self):
        """
        Return the performance statistics from the last backtest run.
        
        Note: Money objects as converted to floats.
        
        Statistics Keys
        ---------------
        - PNL
        - PNL%
        - MaxWinner
        - AvgWinner
        - MinWinner
        - MinLoser
        - AvgLoser
        - MaxLoser
        - WinRate
        - Expectancy
        - AnnualReturn
        - CumReturn
        - MaxDrawdown
        - AnnualVol
        - SharpeRatio
        - CalmarRatio
        - SortinoRatio
        - OmegaRatio
        - Stability
        - ReturnsMean
        - ReturnsVariance
        - ReturnsSkew
        - ReturnsKurtosis
        - TailRatio
        - Alpha
        - Beta
        
        :return: Dict[str, float].
        """
        return self.portfolio.analyzer.get_performance_stats()

    cpdef void reset(self):
        """
        Reset the backtest engine. The data client, execution client, trader and all strategies are reset.
        """
        self.log.info(f"Resetting...")
        self.data_client.reset()
        self.exec_client.reset()
        self.trader.reset()
        self.log.info("Reset.")

    cpdef void dispose(self):
        """
        Dispose of the backtest engine by disposing the trader and releasing system resources.
        """
        self.trader.dispose()

    cdef void _engine_header(self):
        """
        Create a backtest engine log header.
        """
        self.log.info("#---------------------------------------------------------------#")
        self.log.info("#----------------------- BACKTEST ENGINE -----------------------#")
        self.log.info("#---------------------------------------------------------------#")
        self.log.info(f"Nautilus Trader v{__version__} for Invariance Pte. Limited.")
        self.log.info(f"OS: {platform.platform()}")
        self.log.info(f"Processors: {platform.processor()}")
        self.log.info(f"RAM-Total: {round(psutil.virtual_memory()[0] / 1000000)}MB")
        self.log.info("#---------------------------------------------------------------#")
        self.log.info(f"python v{python_version()}")
        self.log.info(f"cython v{cython.__version__}")
        self.log.info(f"numpy v{np.__version__}")
        self.log.info(f"scipy v{scipy.__version__}")
        self.log.info(f"pandas v{pd.__version__}")
        self.log.info(f"empyrical v{empyrical.__version__}")
        self.log.info(f"pymc3 v{pymc3.__version__}")
        self.log.info("#---------------------------------------------------------------#")
        self.log.info("Building engine...")

    cdef void _backtest_header(
            self,
            datetime run_started,
            datetime start,
            datetime stop,
            int time_step_mins):
        """
        Create a backtest run log header.
        """
        self.log.info("#---------------------------------------------------------------#")
        self.log.info("#----------------------- BACKTEST RUN --------------------------#")
        self.log.info("#---------------------------------------------------------------#")
        self.log.info(f"RAM-Used:  {round(psutil.virtual_memory()[3] / 1000000)}MB")
        self.log.info(f"RAM-Avail: {round(psutil.virtual_memory()[1] / 1000000)}MB ({100 - psutil.virtual_memory()[2]}%)")
        self.log.info(f"Run started datetime: {format_zulu_datetime(run_started, timespec='milliseconds')}")
        self.log.info(f"Backtest start datetime: {format_zulu_datetime(start)}")
        self.log.info(f"Backtest stop datetime:  {format_zulu_datetime(stop)}")
        self.log.info(f"Time-step: {time_step_mins} minute")
        self.log.info(f"Account balance (starting): {self.config.starting_capital} {currency_string(self.account.currency)}")
        self.log.info("#---------------------------------------------------------------#")

    cdef void _backtest_footer(
            self,
            datetime run_started,
            datetime start,
            datetime stop):
        """
        Create a backtest run log footer. f'{value:.{decimals}f}'
        """
        self.log.info("#---------------------------------------------------------------#")
        self.log.info("#-------------------- BACKTEST DIAGNOSTICS ---------------------#")
        self.log.info("#---------------------------------------------------------------#")
        self.log.info(f"Run started datetime: {format_zulu_datetime(run_started, timespec='milliseconds')}")
        self.log.info(f"Elapsed time (engine initialization): {self.time_to_initialize:.2f}s")
        self.log.info(f"Elapsed time (running backtest): {self.clock.get_elapsed(run_started):.2f}s")
        self.log.info(f"Time-step iterations: {self.exec_client.iteration}")
        self.log.info(f"Backtest start datetime: {format_zulu_datetime(start)}")
        self.log.info(f"Backtest stop datetime:  {format_zulu_datetime(stop)}")
        self.log.info(f"Account balance (starting): {self.config.starting_capital} {currency_string(self.account.currency)}")
        self.log.info(f"Account balance (ending):   {self.account.cash_balance} {currency_string(self.account.currency)}")
        self.log.info(f"Commissions (total):        {self.exec_client.total_commissions} {currency_string(self.account.currency)}")
        self.log.info("")
        self.log.info("#---------------------------------------------------------------#")
        self.log.info("#-------------------- PERFORMANCE STATISTICS -------------------#")
        self.log.info("#---------------------------------------------------------------#")

        for stat in self.portfolio.analyzer.get_performance_stats_formatted():
            self.log.info(stat)

        self.log.info("#-----------------------------------------------------------------#")

    cdef void _change_strategy_clocks_and_loggers(self, list strategies):
        """
        Replace the clocks and loggers for every strategy in the given list.
        
        :param strategies: The list of strategies.
        """
        for strategy in strategies:
            # Replace the strategies clock with the engines test clock
            strategy.change_clock(TestClock())  # Separate test clocks to iterate independently
            # Replace the strategies logger with the engines test logger
            strategy.change_logger(self.test_logger)
