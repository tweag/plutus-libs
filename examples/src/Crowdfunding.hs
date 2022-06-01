{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# OPTIONS_GHC -fno-ignore-interface-pragmas #-}
{-# OPTIONS_GHC -fno-omit-interface-pragmas #-}
{-# OPTIONS_GHC -fno-specialise #-}

-- These language extensions are just what Split.hs uses

-- | Arrange an auction with a preset deadline and minimum bid.
module Crowdfunding where

import qualified Ledger as L
import qualified Ledger.Ada as Ada
import qualified Ledger.Interval as Interval
import Ledger.Typed.Scripts as Scripts
import qualified Ledger.Value as Value
import qualified PlutusTx
import PlutusTx.Prelude
import qualified Prelude as Haskell
import Test.QuickCheck (functionBoundedEnum)

-- * Data types

-- | All the data associated with crowdfunding that the validator needs to know
data PolicyParams = PolicyParams
  { -- | project must be funded by this time
    projectDeadline :: L.POSIXTime,
    -- | amount that must be reached for project to be funded
    threshold :: L.Value,
    -- | address to be paid to if threshold is reached by deadline
    fundingTarget :: L.PubKeyHash,
    -- | TokenName of the thread token
    pThreadTokenName :: Value.TokenName
  }
  deriving (Haskell.Show)

-- some Plutus magic to compile the data type
PlutusTx.makeLift ''PolicyParams
PlutusTx.unstableMakeIsData ''PolicyParams

-- Information about funder. This will be the 'DatumType'
data FunderInfo = FunderInfo
  { -- | the last funder's contribution
    fund :: L.Value,
    -- | the last funder's address
    funder :: L.PubKeyHash
  }
  deriving (Haskell.Show)

PlutusTx.makeLift ''FunderInfo
PlutusTx.unstableMakeIsData ''FunderInfo

instance Eq FunderInfo where
  {-# INLINEABLE (==) #-}
  FunderInfo a b == FunderInfo x y = a == x && b == y

-- -- | The state of the crowdfund. This will be the 'DatumType'.
-- data CrowdfundingState
--   = -- | state without any funders
--     NoFunds
--   | -- | state with at least one funder
--     Funding FunderInfo
--   deriving (Haskell.Show)

-- PlutusTx.makeLift ''CrowdfundingState
-- PlutusTx.unstableMakeIsData ''CrowdfundingState

-- instance Eq CrowdfundingState where
--   {-# INLINEABLE (==) #-}
--   NoFunds == NoFunds = True
--   Funding a == Funding x = a == x
--   _ == _ = False

-- | Actions to be taken in an auction. This will be the 'RedeemerType' 
data Action
  = -- | Burn master token, pay funds to owner
    Burn
  | -- | Refund all contributors
    IndividualRefund
  deriving (Haskell.Show)

PlutusTx.makeLift ''Action
PlutusTx.unstableMakeIsData ''Action

-- * The minting policy of the thread token

-- | This minting policy controls the thread token of a crowdfund. This
-- token belongs to the validator of the auction, and must be minted (exactly once)
-- in the first transaction, for which this policy ensures that
-- * exactly one thread token is minted, by forcing an UTxO to be consumed
-- * after the transaction:
--     * the validator locks the thread token and the lot of the auction
--     * the validator is in 'NoBids' state
-- The final "hammer" transaction of the auction is the one that burns
-- the thread token. This transaction has its own validator
-- 'validHammer', so that this minting policy only checks that at
-- exactly one token is burned.
{-# INLINEABLE mkPolicy #-}
mkPolicy :: PolicyParams -> L.Address -> L.ScriptContext -> Bool
mkPolicy (PolicyParams _ _ _ tName) validator ctx
  | amnt == Just 1 =
    case filter
    (\o -> L.txOutAddress o == validator)
    (L.txInfoOutputs txi) of
      [o] ->
        traceIfFalse
        "Validator does not recieve the thread token of freshly opened crowdfund"
        (L.txOutValue o `Value.geq` token)
      _ -> trace "There must be exactly one output to the validator on a fresh crowdfund" False
  | amnt == Just (-1) =
    True -- no further checks here; 'validHammer' checks everything
  | otherwise = trace "not minting or burning the right amount" False
  where
    txi = L.scriptContextTxInfo ctx
    L.Minting me = L.scriptContextPurpose ctx

    token :: L.Value
    token = Value.singleton me tName 1

    amnt :: Maybe Integer
    amnt = case Value.flattenValue (L.txInfoMint txi) of
      [(cs, tn, a)] | cs == L.ownCurrencySymbol ctx && tn == tName -> Just a
      _ -> Nothing

{-# INLINEABLE threadTokenName #-}
threadTokenName :: Value.TokenName
threadTokenName = Value.tokenName "CrowdfundingToken"

threadTokenPolicy :: PolicyParams -> Scripts.MintingPolicy
threadTokenPolicy pars =
  L.mkMintingPolicyScript $
    $$(PlutusTx.compile [||Scripts.wrapMintingPolicy . mkPolicy||])
      `PlutusTx.applyCode` PlutusTx.liftCode pars

{- INLINEABLE bidTimeRange -}
crowdfundTimeRange :: PolicyParams -> L.POSIXTimeRange
crowdfundTimeRange a = Interval.to (projectDeadline a)

{- INLINEABLE hammerTimeRange -}
hammerTimeRange :: PolicyParams -> L.POSIXTimeRange
hammerTimeRange a = Interval.from (projectDeadline a)

-- | Test that the value paid to the giv,en public key address is at
-- least the given value

{- INLINEABLE receivesFrom -}
receivesFrom :: L.TxInfo -> L.PubKeyHash -> L.Value -> Bool
receivesFrom txi who what = L.valuePaidTo txi who `Value.geq` what

{- INLINEABLE validateRefunding -}
validRefunding :: L.Value -> L.PubKeyHash -> L.ScriptContext -> Bool
validRefunding amt addr ctx =
  let txi = L.scriptContextTxInfo ctx
      receives = receivesFrom txi
  in addr `receives` amt

{- INLINEABLE validHammer -}
validFund :: PolicyParams -> L.Value -> L.PubKeyHash -> L.ScriptContext -> Bool
validFund cf _ addr ctx =
  let txi = L.scriptContextTxInfo ctx
  in traceIfFalse
       "Contributions after the deadline are not permitted"
       (crowdfundTimeRange cf `Interval.contains` L.txInfoValidRange txi)
       && traceIfFalse "Funding transaction not signed by bidder" (txi `L.txSignedBy` addr)

{- INLINEABLE validate -}
validate :: PolicyParams -> FunderInfo -> Action -> L.ScriptContext -> Bool
validate cf (FunderInfo amt addr) Burn ctx = validFund cf amt addr ctx
validate _  (FunderInfo amt addr) IndividualRefund ctx =
  traceIfFalse "Contributor is not refunded" (validRefunding amt addr ctx)

data Crowdfunding

instance Scripts.ValidatorTypes Crowdfunding where
  type RedeemerType Crowdfunding = Action
  type DatumType Crowdfunding = FunderInfo

crowdfundingValidator :: PolicyParams -> Scripts.TypedValidator Crowdfunding
crowdfundingValidator =
  Scripts.mkTypedValidatorParam @Crowdfunding
    $$(PlutusTx.compile [||validate||])
    $$(PlutusTx.compile [||wrap||])
  where
    wrap = Scripts.wrapValidator @FunderInfo @Action
