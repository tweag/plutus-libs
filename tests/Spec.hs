-- import qualified Cooked.BalanceSpec as Ba

import qualified Cooked.Behaviour as Behaviour
import qualified Cooked.Unit as Unit
-- import qualified Cooked.MockChain.Monad.StagedSpec as StagedSpec
-- import qualified Cooked.MockChain.UtxoStateSpec as UtxoStateSpec
-- import qualified Cooked.WalletSpec as WalletSpec
-- import qualified Cooked.OutputReorderingSpec as OutputReorderingSpec
-- import qualified Cooked.QuickValueSpec as QuickValueSpec
import Test.Tasty

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests =
  testGroup
    "cooked-validators"
    [ -- testGroup "Reordering outputs" OutputReorderingSpec.tests,
      -- testGroup "Balancing transactions" Ba.tests,
      -- testGroup "Quick values" QuickValueSpec.tests,
      -- testGroup "Staged monad" StagedSpec.tests,
      -- testGroup "UtxoState" UtxoStateSpec.tests,
      -- testGroup "Wallet" WalletSpec.tests,
      Unit.tests,
      Behaviour.tests
    ]