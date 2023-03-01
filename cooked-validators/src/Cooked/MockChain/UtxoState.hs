module Cooked.MockChain.UtxoState
  ( UtxoState (..),
    UtxoPayloadSet (..),
    UtxoPayload (..),
    holdingInState,
  )
where

import Cooked.Skeleton (TxSkelOutDatum)
import Cooked.Wallet (Wallet, walletAddress)
import Data.Function (on)
import qualified Data.List as List
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Ledger as Pl hiding (Value)
import qualified Plutus.V1.Ledger.Value as Pl1

-- TODO Migrate to V2 values (see imports)

-- | A 'UtxoState' provides us with the mental picture of the state of the UTxO graph:
-- Each address has a set of UTxOs that consist in a value, some potential
-- datum, and some potential reference script.
newtype UtxoState = UtxoState {utxoState :: Map Pl.Address UtxoPayloadSet}
  deriving (Eq)

-- | Helper function to compute what the given wallet owns in the
-- given state
holdingInState :: UtxoState -> Wallet -> Pl1.Value
holdingInState (UtxoState m) w
  | Just vs <- Map.lookup (walletAddress w) m = utxoPayloadSetTotal vs
  | otherwise = mempty

instance Semigroup UtxoState where
  (UtxoState a) <> (UtxoState b) = UtxoState $ Map.unionWith (<>) a b

-- | Represents a /set/ of payloads. Payloads are the name we give to the
-- information we care about on a UTxO: value, typed datum (wrapped in
-- 'TxSkelOutDatum' which also informs about whether it hashed or inlined), and
-- reference script. We use a list instead of a set because 'Pl.Value' doesn't
-- implement 'Ord' and because it is possible that we want to distinguish
-- between UTxO states that have additional UTxO, even if these could have been
-- merged together.
newtype UtxoPayloadSet = UtxoPayloadSet {utxoPayloadSet :: [UtxoPayload]}
  deriving (Show)

data UtxoPayload = UtxoPayload
  { utxoPayloadTxOutRef :: Pl.TxOutRef,
    utxoPayloadValue :: Pl1.Value,
    utxoPayloadSkelOutDatum :: TxSkelOutDatum,
    utxoPayloadReferenceScript :: Maybe Pl.ScriptHash
  }
  deriving (Eq, Show)

instance Eq UtxoPayloadSet where
  (UtxoPayloadSet xs) == (UtxoPayloadSet ys) = xs' == ys'
    where
      k (UtxoPayload ref val dat rs) = (ref, Pl1.flattenValue val, dat, rs)
      xs' = List.sortBy (compare `on` k) xs
      ys' = List.sortBy (compare `on` k) ys

instance Semigroup UtxoPayloadSet where
  UtxoPayloadSet a <> UtxoPayloadSet b = UtxoPayloadSet $ a ++ b

instance Monoid UtxoPayloadSet where
  mempty = UtxoPayloadSet []

-- | Computes the total value in a 'UtxoPayloadSet'.
utxoPayloadSetTotal :: UtxoPayloadSet -> Pl1.Value
utxoPayloadSetTotal = mconcat . fmap utxoPayloadValue . utxoPayloadSet
