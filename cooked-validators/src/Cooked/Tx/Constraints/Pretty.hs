{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

module Cooked.Tx.Constraints.Pretty where

import Cooked.MockChain.UtxoState
import Cooked.MockChain.Wallet
import Cooked.Tx.Constraints.Type
import Data.Maybe (catMaybes)
import qualified Ledger as Pl hiding (unspentOutputs)
import qualified Ledger.Typed.Scripts as Pl (DatumType, RedeemerType, TypedValidator, validatorScript)
import qualified PlutusTx as Pl
import Prettyprinter (Doc, (<+>))
import qualified Prettyprinter as PP

instance Show Constraint where
  show = show . prettyConstraint

prettyTxSkel :: TxSkel -> Doc ann
prettyTxSkel (TxSkel lbl signer constr) =
  PP.hang 2 $
    PP.vsep $
      catMaybes
        [ Just $ prettyWallet signer,
          fmap (("User label:" <+>) . PP.viaShow) lbl,
          Just $ PP.vsep (map (("*" <+>) . prettyConstraint) constr)
        ]

prettyWallet :: Wallet -> Doc ann
prettyWallet w =
  "wallet" <+> (maybe prettyWHash (("#" <>) . PP.pretty) . walletPKHashToId . walletPKHash $ w)
  where
    prettyWHash = PP.viaShow (take 6 $ show (walletPKHash w))

prettyConstraint :: Constraint -> Doc ann
prettyConstraint (PaysScript val outs) =
  PP.hang 2 $
    PP.vsep
      ( "PaysScript" <+> prettyTypedValidator val :
        map ((<+>) "-" . uncurry (prettyDatumVal val)) outs
      )
prettyConstraint _ = "<constraint>"

prettyTypedValidator :: Pl.TypedValidator a -> Doc ann
prettyTypedValidator = prettyAddressTypeAndHash . Pl.scriptAddress . Pl.validatorScript

prettyDatumVal ::
  (Show (Pl.DatumType a)) =>
  Pl.TypedValidator a ->
  Pl.DatumType a ->
  Pl.Value ->
  Doc ann
prettyDatumVal _ d val =
  PP.sep ["-", PP.align $ PP.vsep $ catMaybes [Just $ PP.viaShow d, mPrettyValue val]]
