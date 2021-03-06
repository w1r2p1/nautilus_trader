# -------------------------------------------------------------------------------------------------
#  Copyright (C) 2015-2021 Nautech Systems Pty Ltd. All rights reserved.
#  https://nautechsystems.io
#
#  Licensed under the GNU Lesser General Public License Version 3.0 (the "License");
#  You may not use this file except in compliance with the License.
#  You may obtain a copy of the License at https://www.gnu.org/licenses/lgpl-3.0.en.html
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
# -------------------------------------------------------------------------------------------------

import unittest

from nautilus_trader.common.clock import LiveClock
from nautilus_trader.common.clock import TestClock
from nautilus_trader.common.factories import OrderFactory
from nautilus_trader.common.generators import ClientOrderIdGenerator
from nautilus_trader.model.enums import OrderSide
from nautilus_trader.model.identifiers import IdTag
from nautilus_trader.model.identifiers import StrategyId
from nautilus_trader.model.identifiers import TraderId
from nautilus_trader.model.objects import Price
from nautilus_trader.model.objects import Quantity
from tests.test_kit.performance import PerformanceHarness
from tests.test_kit.stubs import TestStubs


AUDUSD_SIM = TestStubs.symbol_audusd()


class OrderPerformanceTests(unittest.TestCase):

    def setUp(self):
        # Fixture Setup
        self.generator = ClientOrderIdGenerator(IdTag("001"), IdTag("001"), LiveClock())
        self.order_factory = OrderFactory(
            trader_id=TraderId("TESTER", "000"),
            strategy_id=StrategyId("S", "001"),
            clock=TestClock(),
        )

    def create_market_order(self):
        self.order_factory.market(
            AUDUSD_SIM,
            OrderSide.BUY,
            Quantity(100000),
        )

    def create_limit_order(self):
        self.order_factory.limit(
            AUDUSD_SIM,
            OrderSide.BUY,
            Quantity(100000),
            Price("0.80010"),
        )

    def test_order_id_generator(self):
        PerformanceHarness.profile_function(self.generator.generate, 100000, 1)
        # ~0.0ms / ~2.9μs / 2894ns minimum of 100,000 runs @ 1 iteration each run.

    def test_market_order_creation(self):
        PerformanceHarness.profile_function(self.create_market_order, 10000, 1)
        # ~0.0ms / ~13.8μs / 13801ns minimum of 10,000 runs @ 1 iteration each run.

    def test_limit_order_creation(self):
        PerformanceHarness.profile_function(self.create_limit_order, 10000, 1)
        # ~0.0ms / ~17.4μs / 17362ns minimum of 10,000 runs @ 1 iteration each run.
