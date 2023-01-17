{-# LANGUAGE DataKinds #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module Cooked.ReferenceInputsSpec where

import Cooked.Pretty
import qualified Plutus.Script.Utils.V2.Typed.Scripts as Pl
import qualified Plutus.V2.Ledger.Api as Pl
import qualified PlutusTx
import qualified PlutusTx as Pl
import qualified PlutusTx.Prelude as Pl
import Prettyprinter (Pretty)
import qualified Prettyprinter as PP
import qualified Test.Tasty as Tasty

-- Foo and Bar are two dummy scripts to test reference inputs. They serve no
-- purpose and make no real sense.
--
-- Foo contains a pkh in its datum. It can only be spent by ANOTHER public key.
--
-- Bar has no datum nor redeemer. Its outputs can only be spent by a public key
-- who can provide a Foo UTxO containing its pkh as reference input (that is a
-- UTxO they could not actually spend, according the the design of Foo).
--
-- The datum in Foo outputs in expected to be inlined.

data Foo

data FooDatum = FooDatum Pl.PubKeyHash deriving (Show)

instance Pretty FooDatum where
  pretty (FooDatum pkh) = "FooDatum" PP.<+> prettyPubKeyHash pkh

instance Pl.Eq FooDatum where
  FooDatum pkh1 == FooDatum pkh2 = pkh1 == pkh2

PlutusTx.makeLift ''FooDatum
PlutusTx.unstableMakeIsData ''FooDatum

instance Pl.ValidatorTypes Foo where
  type RedeemerType Foo = ()
  type DatumType Foo = FooDatum

-- | Outputs can only be spent by pks whose hash is not the one in the datum.
fooValidator :: FooDatum -> () -> Pl.ScriptContext -> Bool
fooValidator (FooDatum pkh) _ (Pl.ScriptContext txInfo _) =
  not $ elem pkh (Pl.txInfoSignatories txInfo)

fooTypedValidator :: Pl.TypedValidator Foo
fooTypedValidator =
  let wrap = Pl.mkUntypedValidator @FooDatum @()
   in Pl.mkTypedValidator @Foo
        $$(Pl.compile [||fooValidator||])
        $$(Pl.compile [||wrap||])

data Bar

instance Pl.ValidatorTypes Bar where
  type RedeemerType Bar = ()
  type DatumType Bar = ()

-- | Outputs can only be spent by pks who provide a reference input to a Foo in
-- which they are mentioned (in an inlined datum).
barValidator :: () -> () -> Pl.ScriptContext -> Bool
barValidator _ _ (Pl.ScriptContext txInfo _) =
  (not . null) (filter f (Pl.txInfoReferenceInputs txInfo))
  where
    f :: Pl.TxInInfo -> Bool
    f
      ( Pl.TxInInfo
          _
          (Pl.TxOut address _ (Pl.OutputDatum (Pl.Datum datum)) _)
        ) =
        address == Pl.validatorAddress fooTypedValidator
          && case Pl.fromBuiltinData @FooDatum datum of
            Nothing -> False
            Just (FooDatum pkh) -> elem pkh (Pl.txInfoSignatories txInfo)
    f _ = False

barTypedValidator :: Pl.TypedValidator Bar
barTypedValidator =
  let wrap = Pl.mkUntypedValidator @() @()
   in Pl.mkTypedValidator @Bar
        $$(Pl.compile [||barValidator||])
        $$(Pl.compile [||wrap||])

tests :: Tasty.TestTree
tests =
  Tasty.testGroup
    "Reference inputs"
    []
