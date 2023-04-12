{-# LANGUAGE DataKinds #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | Validators to be used in tests. Validators defined here use no particular
-- datum or redeemer type (but not '()', as those are in
-- 'Cooked.Validators.Unit').
--
-- This module should be qualified to avoid clashes with Plutus
-- > import qualified Cooked.Validators.Other as Validators
module Cooked.Validators.Other
  ( pkNotInDatum,
    PubKey,
    BoolR,
    yesBoolR,
    Gearbox (..),
    ThreeR,
    yesThreeR,
    BoolD,
    carefulBoolD,
    carelessBoolD,
  )
where

import Cooked (PrettyCooked (..))
import qualified Plutus.Script.Utils.Typed as Scripts
import qualified Plutus.Script.Utils.V2.Typed.Scripts as Scripts
import Plutus.V2.Ledger.Api as PV2
import Plutus.V2.Ledger.Contexts as PV2
import PlutusTx
import PlutusTx.Builtins ()
import PlutusTx.Lift ()
import PlutusTx.Prelude
import Prettyprinter (viaShow)
import qualified Prelude as Haskell

-- * Boolean redeemer

data BoolR

instance Scripts.ValidatorTypes BoolR where
  type RedeemerType BoolR = Bool
  type DatumType BoolR = ()

-- | The validator that accepts a boolean redeemer but always succeeds.
yesBoolR :: Scripts.TypedValidator BoolR
yesBoolR =
  Scripts.mkTypedValidator @BoolR
    $$(compile [||val||])
    $$(compile [||wrap||])
  where
    wrap = Scripts.mkUntypedValidator
    val _ _ _ = True

-- * Boolean datum

data BoolD

instance Scripts.ValidatorTypes BoolD where
  type RedeemerType BoolD = ()
  type DatumType BoolD = Bool

-- | Extract the boolean out of a datum (used with datum of 'BoolD' contracts).
{-# INLINEABLE outputDatum #-}
outputDatum :: TxInfo -> TxOut -> Maybe Bool
outputDatum txi o = case txOutDatum o of
  NoOutputDatum -> Nothing
  OutputDatumHash h -> do
    Datum d <- findDatum h txi
    fromBuiltinData d
  OutputDatum (Datum d) -> fromBuiltinData d

-- | If the datum is 'True', ensure the first output returned by the given
-- function has an output already locked (with datum 'False') and that the
-- value is the same. Otherwise, fail.
mkMockValidator :: (ScriptContext -> [TxOut]) -> Value -> Bool -> () -> ScriptContext -> Bool
mkMockValidator getOutputs lockValue datum _ ctx =
  let txi = scriptContextTxInfo ctx
   in ( datum
          && ( case getOutputs ctx of
                 o : _ ->
                   traceIfFalse
                     "not in 'SecondLock'-state after re-locking"
                     (outputDatum txi o == Just False)
                     && traceIfFalse
                       "not re-locking the right amout"
                       (txOutValue o == lockValue)
                 _ -> trace "there must be an output re-locked" False
             )
      )

-- | This is a very simple contract: The first transaction locks some Ada to the
-- validator, using the datum 'True', the second transaction then re-locks
-- the same amount to the same validator, using the datum 'False'.
carefulBoolD :: Value -> Scripts.TypedValidator BoolD
carefulBoolD =
  Scripts.mkTypedValidatorParam @BoolD
    $$(compile [||val||])
    $$(compile [||wrap||])
  where
    wrap = Scripts.mkUntypedValidator
    val :: Value -> Bool -> () -> ScriptContext -> Bool
    val = mkMockValidator getContinuingOutputs

carelessBoolD :: Value -> Scripts.TypedValidator BoolD
carelessBoolD =
  Scripts.mkTypedValidatorParam @BoolD
    $$(compile [||val||])
    $$(compile [||wrap||])
  where
    wrap = Scripts.mkUntypedValidator
    val :: Value -> Bool -> () -> ScriptContext -> Bool
    val = mkMockValidator (txInfoOutputs . PV2.scriptContextTxInfo)

-- * Redeemer with three values

-- | Arbitrary names, just three values
data Gearbox = GbRear | GbNeutral | GbForward deriving (Haskell.Show)

instance Eq Gearbox where
  GbRear == GbRear = True
  GbNeutral == GbNeutral = True
  GbForward == GbForward = True
  _ == _ = False

instance PrettyCooked Gearbox where
  prettyCookedOpt _ = viaShow

makeLift ''Gearbox
unstableMakeIsData ''Gearbox

-- | Validators with a redeemer with three values.
data ThreeR

instance Scripts.ValidatorTypes ThreeR where
  type RedeemerType ThreeR = Gearbox
  type DatumType ThreeR = ()

-- | The validator that always succeeds.
yesThreeR :: Scripts.TypedValidator ThreeR
yesThreeR =
  Scripts.mkTypedValidator @ThreeR
    $$(compile [||val||])
    $$(compile [||wrap||])
  where
    wrap = Scripts.mkUntypedValidator
    val _ _ _ = True

-- * A datum made of a public key

data PubKey

instance Scripts.ValidatorTypes PubKey where
  type RedeemerType PubKey = ()
  type DatumType PubKey = PubKeyHash

-- | Outputs can only be spent by pubkeys whose hash is not the one in the datum.
pkNotInDatum :: Scripts.TypedValidator PubKey
pkNotInDatum =
  Scripts.mkTypedValidator @PubKey
    $$(compile [||val||])
    $$(compile [||wrap||])
  where
    val :: PubKeyHash -> () -> ScriptContext -> Bool
    val pkh _ (ScriptContext txInfo _) =
      pkh `notElem` txInfoSignatories txInfo
    wrap = Scripts.mkUntypedValidator
