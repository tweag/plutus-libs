-- | This module provides utilities to work with Value
module Cooked.ValueUtils
  ( flattenValueI,
    positivePart,
    negativePart,
    adaL,
  )
where

import Data.List
import Optics.Core
import Plutus.Script.Utils.Ada qualified as Script
import Plutus.Script.Utils.Value qualified as Script hiding (adaSymbol, adaToken)
import PlutusLedgerApi.V3 qualified as Api
import PlutusTx.Numeric qualified as PlutusTx

flattenValueI :: Iso' Api.Value [(Script.AssetClass, Integer)]
flattenValueI =
  iso
    (map (\(cSymbol, tName, amount) -> (Script.assetClass cSymbol tName, amount)) . Script.flattenValue)
    (foldl' (\v (ac, amount) -> v <> Script.assetClassValue ac amount) mempty)

-- | The positive part of a value. For every asset class in the given value,
-- this asset class and its amount are included in the output iff the amount is
-- strictly positive. It holds
--
-- > x == positivePart x <> Script.negate negativePart x
positivePart :: Api.Value -> Api.Value
positivePart = over flattenValueI (filter $ (0 <) . snd)

-- | The negative part of a value. For every asset class in the given value,
-- this asset class and its negated amount are included in the output iff the
-- amount is strictly negative. It holds
--
-- > x == positivePart x <> Script.negate negativePart x
negativePart :: Api.Value -> Api.Value
negativePart = positivePart . PlutusTx.negate

-- | Focus the Ada part in a value.
adaL :: Lens' Api.Value Script.Ada
adaL =
  lens
    Script.fromValue
    ( \value (Script.Lovelace amount) ->
        over
          flattenValueI
          (\l -> insertAssocList l adaAssetClass amount)
          value
    )
  where
    insertAssocList :: (Eq a) => [(a, b)] -> a -> b -> [(a, b)]
    insertAssocList l a b = (a, b) : filter ((/= a) . fst) l
    adaAssetClass = Script.assetClass Script.adaSymbol Script.adaToken
