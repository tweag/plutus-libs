-- | This module introduces standard dummy validators to be used in
-- attacks, traces or tests. More precisely, it introduces the always
-- True and always False validators, which will respectively always
-- succeed or always fail.
module Cooked.Validators
  ( alwaysTrueValidator,
    alwaysFalseValidator,
    MockContract,
  )
where

import Plutus.Script.Utils.Scripts qualified as Script
import Plutus.Script.Utils.Typed qualified as Script hiding (validatorHash)
import Plutus.Script.Utils.V3.Generators qualified as Script
import Plutus.Script.Utils.V3.Typed.Scripts.MonetaryPolicies qualified as Script
import PlutusTx.Prelude qualified as PlutusTx
import PlutusTx.TH qualified as PlutusTx

validatorToTypedValidator :: Script.Validator -> Script.TypedValidator a
validatorToTypedValidator val =
  Script.TypedValidator
    { Script.tvValidator = vValidator,
      Script.tvValidatorHash = vValidatorHash,
      Script.tvForwardingMPS = vMintingPolicy,
      Script.tvForwardingMPSHash = Script.mintingPolicyHash vMintingPolicy
    }
  where
    vValidator = Script.Versioned val Script.PlutusV3
    vValidatorHash = Script.validatorHash vValidator
    forwardingPolicy = Script.mkForwardingMintingPolicy vValidatorHash
    vMintingPolicy = Script.Versioned forwardingPolicy Script.PlutusV3

-- | The trivial validator that always succeds; this is in particular
-- a sufficient target for the datum hijacking attack since we only
-- want to show feasibility of the attack.
alwaysTrueValidator :: forall a. Script.TypedValidator a
alwaysTrueValidator = validatorToTypedValidator @a Script.alwaysSucceedValidator

-- -- | The trivial validator that always fails
alwaysFalseValidator :: forall a. Script.TypedValidator a
alwaysFalseValidator = validatorToTypedValidator @a $ Script.mkValidatorScript $$(PlutusTx.compile [||\_ _ _ -> PlutusTx.error ()||])

-- -- | A Mock contract type to instantiate validators with
data MockContract

instance Script.ValidatorTypes MockContract where
  type RedeemerType MockContract = ()
  type DatumType MockContract = ()
