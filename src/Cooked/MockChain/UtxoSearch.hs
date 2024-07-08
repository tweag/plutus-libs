-- | This module provides a convenient framework to look through UTxOs and
-- search relevant ones based on predicates. For instance, it makes it very
-- convenient to gather all UTxOs at a certain address.
module Cooked.MockChain.UtxoSearch
  ( UtxoSearch,
    runUtxoSearch,
    allUtxosSearch,
    allUtxosLedgerSearch,
    utxosAtSearch,
    utxosAtLedgerSearch,
    utxosFromCardanoTxSearch,
    txOutByRefSearch,
    filterWithTxOutRef,
    filterWith,
    filterWithPure,
    filterWithOptic,
    filterWithPred,
    filterWithValuePred,
    filterWithOnlyAda,
    filterWithNotOnlyAda,
    onlyValueOutputsAtSearch,
    vanillaOutputsAtSearch,
    filterWithAlways,
    scriptOutputsSearch,
    referenceScriptOutputsSearch,
  )
where

import Control.Monad
import Cooked.Conversion.ToAddress
import Cooked.Conversion.ToScriptHash
import Cooked.MockChain.BlockChain
import Cooked.Output
import Data.Maybe
import Ledger.Tx qualified as Ledger
import ListT (ListT (..))
import ListT qualified
import Optics.Core
import Plutus.Script.Utils.Ada qualified as Script
import Plutus.Script.Utils.Value qualified as Script
import PlutusLedgerApi.V3 qualified as Api

-- * The type of UTxO searches

-- | If a UTxO is a 'TxOutRef' with some additional information, this type
-- captures a "stream" of UTxOs.
type UtxoSearch m a = ListT m (Api.TxOutRef, a)

-- | Given a UTxO search, we can run it to obtain a list of UTxOs.
runUtxoSearch :: (Monad m) => UtxoSearch m a -> m [(Api.TxOutRef, a)]
runUtxoSearch = ListT.toList

-- | Search all currently known 'TxOutRef's together with their corresponding
-- 'TxInfo'-'TxOut'.
allUtxosSearch :: (MonadBlockChain m) => UtxoSearch m Api.TxOut
allUtxosSearch = allUtxos >>= ListT.fromFoldable

-- | Like 'allUtxosSearch', but returns a Ledger-level representation of the
-- transaction outputs, which might contain more information.
allUtxosLedgerSearch :: (MonadBlockChain m) => UtxoSearch m Ledger.TxOut
allUtxosLedgerSearch = allUtxosLedger >>= ListT.fromFoldable

-- | Search all 'TxOutRef's at a certain address, together with their
-- 'TxInfo'-'TxOut'.
utxosAtSearch :: (MonadBlockChainBalancing m, ToAddress addr) => addr -> UtxoSearch m Api.TxOut
utxosAtSearch = utxosAt . toAddress >=> ListT.fromFoldable

-- | Like 'utxosAtSearch', but returns a Ledger-level representation of the
-- transaction outputs, which might contain more information.
utxosAtLedgerSearch :: (MonadBlockChainBalancing m, ToAddress addr) => addr -> UtxoSearch m Ledger.TxOut
utxosAtLedgerSearch = utxosAtLedger . toAddress >=> ListT.fromFoldable

-- | Search all 'TxOutRef's of a transaction, together with their
-- 'TxInfo'-'TxOut'.
utxosFromCardanoTxSearch :: (Monad m) => Ledger.CardanoTx -> UtxoSearch m Api.TxOut
utxosFromCardanoTxSearch = ListT.fromFoldable . utxosFromCardanoTx

-- | Search all 'TxInfo'-'TxOut's corresponding to given the list of
-- 'TxOutRef's. Any 'TxOutRef' that doesn't correspond to a known output will be
-- filtered out.
txOutByRefSearch :: (MonadBlockChainBalancing m) => [Api.TxOutRef] -> UtxoSearch m Api.TxOut
txOutByRefSearch orefs =
  ListT.traverse (\o -> return (o, o)) (ListT.fromFoldable orefs)
    `filterWith` txOutByRef

-- * Most general filtering

filterSearch :: (Monad m) => UtxoSearch m a -> ((Api.TxOutRef, a) -> m (Maybe (Api.TxOutRef, b))) -> UtxoSearch m b
filterSearch (ListT as) f =
  ListT $
    as >>= \case
      Nothing -> return Nothing
      Just (el, (`filterSearch` f) -> filteredRest@(ListT bs)) ->
        f el >>= \case
          Nothing -> bs
          Just el' -> return $ Just (el', filteredRest)

-- * Filtering on TxOutRefs

-- | Transform a 'UtxoSearch' by applying a monadic predicate on a TxOutRef
filterWithTxOutRef :: (Monad m) => UtxoSearch m a -> (Api.TxOutRef -> m Bool) -> UtxoSearch m a
filterWithTxOutRef search predTxOutRef = filterSearch search $
  \(oRef, a) -> do
    res <- predTxOutRef oRef
    return $ if res then Just (oRef, a) else Nothing

-- * Filtering on associated value

-- | Transform a 'UtxoSearch' by applying a possibly failing monadic "lookup" on
-- every output.
filterWith :: (Monad m) => UtxoSearch m a -> (a -> m (Maybe b)) -> UtxoSearch m b
filterWith search predEl = filterSearch search $ \(oref, a) -> ((oref,) <$>) <$> predEl a

filterWithPure :: (Monad m) => UtxoSearch m a -> (a -> Maybe b) -> UtxoSearch m b
filterWithPure as f = filterWith as (return . f)

filterWithAlways :: (Monad m) => UtxoSearch m a -> (a -> b) -> UtxoSearch m b
filterWithAlways as f = filterWithPure as (Just . f)

filterWithOptic :: (Is k An_AffineFold, Monad m) => UtxoSearch m a -> Optic' k is a b -> UtxoSearch m b
filterWithOptic as optic = filterWithPure as (^? optic)

filterWithPred :: (Monad m) => UtxoSearch m a -> (a -> Bool) -> UtxoSearch m a
filterWithPred as f = filterWithPure as $ \a -> if f a then Just a else Nothing

filterWithValuePred :: (Monad m) => UtxoSearch m Api.TxOut -> (Api.Value -> Bool) -> UtxoSearch m Api.Value
filterWithValuePred as p = filterWithPure as $
  \txOut -> let val = Api.txOutValue txOut in if p val then Just val else Nothing

filterWithOnlyAda :: (Monad m) => UtxoSearch m Api.TxOut -> UtxoSearch m Api.Value
filterWithOnlyAda as = filterWithValuePred as $ (1 ==) . length . Script.flattenValue

filterWithNotOnlyAda :: (Monad m) => UtxoSearch m Api.TxOut -> UtxoSearch m Api.Value
filterWithNotOnlyAda as = filterWithValuePred as $ (1 <) . length . Script.flattenValue

-- | Search for UTxOs which only carry address and value information (no datum, staking credential, or reference script).
onlyValueOutputsAtSearch ::
  (MonadBlockChainBalancing m, ToAddress addr) =>
  addr ->
  UtxoSearch m (ConcreteOutput Api.Credential () Api.Value Api.ScriptHash)
onlyValueOutputsAtSearch addr =
  utxosAtSearch addr
    `filterWithAlways` fromAbstractOutput
    `filterWithPure` isOutputWithoutDatum
    `filterWithPure` isEmptyStakingCredentialOutput
    `filterWithPred` (isNothing . view outputReferenceScriptL)

-- | A vanilla output only possesses an ada-only value and does not have a staking
-- credential, a datum or a reference script. A vanilla UTxO is a perfect
-- candidate to be used for fee, balancing or collateral.
vanillaOutputsAtSearch ::
  (MonadBlockChainBalancing m, ToAddress addr) =>
  addr ->
  UtxoSearch m (ConcreteOutput Api.Credential () Script.Ada Api.ScriptHash)
vanillaOutputsAtSearch addr =
  onlyValueOutputsAtSearch addr
    `filterWithPure` isOnlyAdaOutput

scriptOutputsSearch ::
  (MonadBlockChain m, ToScriptHash s) =>
  s ->
  UtxoSearch m (ConcreteOutput s Api.OutputDatum Api.Value Api.ScriptHash)
scriptOutputsSearch s =
  allUtxosSearch
    `filterWithAlways` fromAbstractOutput
    `filterWithPure` isScriptOutputFrom s

referenceScriptOutputsSearch ::
  (MonadBlockChain m, ToScriptHash s) =>
  s ->
  UtxoSearch m (ConcreteOutput Api.Credential Api.OutputDatum Api.Value Api.ScriptHash)
referenceScriptOutputsSearch s =
  allUtxosSearch
    `filterWithAlways` fromAbstractOutput
    `filterWithPure` isReferenceScriptOutputFrom s
