{-# OPTIONS_GHC -Wno-orphans #-}

-- | This module implements pretty-printing for Cooked structures such as
-- skeletons and chain state.
--
-- It contains orphaned instances of 'PrettyCooked' for Cooked datatypes. They
-- cannot be provided in "Cooked.Pretty.Class" because of dependency cycles and,
-- for ease of maintainability, we chose to centralize all pretty-printing
-- related code in submodules of "Cooked.Pretty" instead of having
-- 'PrettyCooked' instances scattered around.
--
-- Some structure require additional arguments to be pretty-printed and have
-- therefore no instances 'PrettyCooked' (for example 'TxSkel' needs some
-- 'TxSkelContext').
module Cooked.Pretty.Cooked
  ( prettyTxSkel,
    prettyBalancingWallet,
    prettySigners,
    prettyMints,
    mPrettyTxOpts,
    prettyTxSkelOut,
    prettyTxSkelOutDatumMaybe,
    prettyTxSkelIn,
    prettyTxSkelInReference,
    prettyAddressState,
    prettyPayloadGrouped,
    prettyPayload,
    prettyReferenceScriptHash,
  )
where

import Cooked.Conversion
import Cooked.MockChain.BlockChain
import Cooked.MockChain.GenerateTx
import Cooked.MockChain.Staged
import Cooked.MockChain.UtxoState
import Cooked.Output
import Cooked.Pretty.Class
import Cooked.Pretty.Common
import Cooked.Pretty.Hashable
import Cooked.Pretty.Options
import Cooked.Skeleton
import Cooked.Wallet
import Data.Default
import Data.Function (on)
import Data.List qualified as List
import Data.Map qualified as Map
import Data.Maybe (catMaybes, mapMaybe)
import Data.Set qualified as Set
import Optics.Core
import Plutus.Script.Utils.Ada qualified as Script
import Plutus.Script.Utils.Scripts qualified as Script
import PlutusLedgerApi.V3 qualified as Api
import Prettyprinter ((<+>))
import Prettyprinter qualified as PP

-- | The 'PrettyCooked' instance for 'TxSkelOutDatum' prints the datum it
-- contains according to its own 'PrettyCooked' instance.
instance PrettyCooked TxSkelOutDatum where
  prettyCookedOpt _ TxSkelOutNoDatum = mempty
  prettyCookedOpt opts (TxSkelOutDatumHash datum) = prettyCookedOpt opts datum
  prettyCookedOpt opts (TxSkelOutDatum datum) = prettyCookedOpt opts datum
  prettyCookedOpt opts (TxSkelOutInlineDatum datum) = prettyCookedOpt opts datum

instance PrettyCooked MockChainError where
  prettyCookedOpt opts (MCEValidationError plutusPhase plutusError) =
    PP.vsep ["Validation error " <+> prettyCookedOpt opts plutusPhase, PP.indent 2 (prettyCookedOpt opts plutusError)]
  -- Here we don't print the skel because we lack its context and this error is
  -- printed alongside the skeleton when a test fails
  prettyCookedOpt opts (MCEUnbalanceable balWallet missingValue _) =
    prettyItemize
      "Unbalanceable:"
      "-"
      [ prettyCookedOpt opts (walletPKHash balWallet) <+> "does not have enough funds",
        if missingValue == mempty
          then "Not enough funds to sustain the minimal ada of the return utxo"
          else "Unable to find" <+> prettyCookedOpt opts missingValue
      ]
  prettyCookedOpt opts (MCENoSuitableCollateral fee percentage colVal) =
    prettyItemize
      "No suitable collateral"
      "-"
      [ "Fee was" <+> prettyCookedOpt opts fee,
        "Percentage in params was" <+> prettyCookedOpt opts percentage,
        "Resulting minimal collateral value was" <+> prettyCookedOpt opts colVal
      ]
  prettyCookedOpt _ (MCEGenerationError (ToCardanoError msg cardanoError)) =
    prettyItemize
      "Transaction generation error:"
      "-"
      [PP.pretty msg, PP.pretty cardanoError]
  prettyCookedOpt _ (MCEGenerationError (GenerateTxErrorGeneral msg)) =
    prettyItemize
      "Transaction generation error:"
      "-"
      [PP.pretty msg]
  prettyCookedOpt _ (MCEGenerationError (TxBodyError msg err)) =
    prettyItemize
      "Transaction generation error:"
      "-"
      [PP.pretty msg, PP.viaShow err]
  prettyCookedOpt opts (MCEUnknownOutRefError msg txOutRef) =
    prettyItemize
      "Unknown transaction output ref:"
      "-"
      [PP.pretty msg, prettyCookedOpt opts txOutRef]
  prettyCookedOpt _ (FailWith msg) =
    "Failed with:" <+> PP.pretty msg
  prettyCookedOpt opts (MCEUnknownValidator msg valHash) =
    prettyItemize
      "Unknown validator hash:"
      "-"
      [PP.pretty msg, "hash:" <+> prettyHash (pcOptHashes opts) (toHash valHash)]
  prettyCookedOpt opts (MCEUnknownDatum msg dHash) =
    prettyItemize
      "Unknown datum hash:"
      "-"
      [PP.pretty msg, "hash:" <+> prettyHash (pcOptHashes opts) (toHash dHash)]

instance (Show a) => PrettyCooked (a, UtxoState) where
  prettyCookedOpt opts (res, state) =
    prettyItemize
      "End state:"
      "-"
      ["Returns:" <+> PP.viaShow res, prettyCookedOpt opts state]

instance (Show a) => PrettyCooked (Either MockChainError (a, UtxoState)) where
  prettyCookedOpt opts (Left err) = "🔴" <+> prettyCookedOpt opts err
  prettyCookedOpt opts (Right endState) = "🟢" <+> prettyCookedOpt opts endState

-- | This pretty prints a 'MockChainLog' that usually consists of the list of
-- validated or submitted transactions. In the log, we know a transaction has
-- been validated if the 'MCLogSubmittedTxSkel' is followed by a 'MCLogNewTx'.
instance PrettyCooked MockChainLog where
  prettyCookedOpt opts =
    prettyEnumerate "MockChain run:" "."
      . go []
      . unMockChainLog
    where
      -- In order to avoid printing 'MockChainLogValidateTxSkel' then
      -- 'MockChainLogNewTx' as two different items, we combine them into one
      -- single 'DocCooked'
      go :: [DocCooked] -> [MockChainLogEntry] -> [DocCooked]
      go
        acc
        ( MCLogSubmittedTxSkel skelContext skel
            : MCLogNewTx txId
            : entries
          )
          | pcOptPrintTxHashes opts =
              go
                ( "Validated"
                    <+> PP.parens ("TxId:" <+> prettyCookedOpt opts txId)
                    <+> prettyTxSkel opts skelContext skel
                    : acc
                )
                entries
          | otherwise = go ("Validated" <+> prettyTxSkel opts skelContext skel : acc) entries
      go
        acc
        ( MCLogSubmittedTxSkel skelContext skel
            : entries
          ) =
          go ("Submitted" <+> prettyTxSkel opts skelContext skel : acc) entries
      go acc (MCLogFail msg : entries) =
        go ("Fail:" <+> PP.pretty msg : acc) entries
      -- This case is not supposed to occur because it should follow a
      -- 'MCLogSubmittedTxSkel'
      go acc (MCLogNewTx txId : entries) =
        go ("New transaction:" <+> prettyCookedOpt opts txId : acc) entries
      go acc [] = reverse acc

prettyTxSkel :: PrettyCookedOpts -> SkelContext -> TxSkel -> DocCooked
prettyTxSkel opts skelContext (TxSkel lbl txopts mints signers validityRange ins insReference outs proposals) =
  prettyItemize
    "transaction skeleton:"
    "-"
    ( catMaybes
        [ prettyItemizeNonEmpty "Labels:" "-" (prettyCookedOpt opts <$> Set.toList lbl),
          mPrettyTxOpts opts txopts,
          prettyItemizeNonEmpty "Mints:" "-" (prettyMints opts <$> txSkelMintsToList mints),
          Just $ "Validity interval:" <+> PP.pretty validityRange,
          prettyItemizeNonEmpty "Signers:" "-" (prettySigners opts txopts signers),
          prettyItemizeNonEmpty "Inputs:" "-" (prettyTxSkelIn opts skelContext <$> Map.toList ins),
          prettyItemizeNonEmpty "Reference inputs:" "-" (mapMaybe (prettyTxSkelInReference opts skelContext) $ Set.toList insReference),
          prettyItemizeNonEmpty "Outputs:" "-" (prettyTxSkelOut opts <$> outs),
          prettyItemizeNonEmpty "Proposals:" "-" (prettyTxSkelProposal opts <$> proposals)
        ]
    )

prettyTxParameterChange :: PrettyCookedOpts -> TxParameterChange -> DocCooked
prettyTxParameterChange opts (FeePerByte n) = "Fee per byte:" <+> prettyCookedOpt opts n
prettyTxParameterChange opts (FeeFixed n) = "Fee fixed:" <+> prettyCookedOpt opts n
prettyTxParameterChange opts (MaxBlockBodySize n) = "Max block body size:" <+> prettyCookedOpt opts n
prettyTxParameterChange opts (MaxTxSize n) = "Max transaction size:" <+> prettyCookedOpt opts n
prettyTxParameterChange opts (MaxBlockHeaderSize n) = "Max block header size:" <+> prettyCookedOpt opts n
prettyTxParameterChange opts (KeyDeposit n) = "Key deposit:" <+> prettyCookedOpt opts n
prettyTxParameterChange opts (PoolDeposit n) = "Pool deposit:" <+> prettyCookedOpt opts n
prettyTxParameterChange opts (PoolRetirementMaxEpoch n) = "Pool retirement max epoch:" <+> prettyCookedOpt opts n
prettyTxParameterChange opts (PoolNumber n) = "Pool number:" <+> prettyCookedOpt opts n
prettyTxParameterChange opts (PoolInfluence q) = "Pool influence:" <+> prettyCookedOpt opts q
prettyTxParameterChange opts (MonetaryExpansion q) = "Monetary expansion:" <+> prettyCookedOpt opts q
prettyTxParameterChange opts (TreasuryCut q) = "Treasury cut:" <+> prettyCookedOpt opts q
prettyTxParameterChange opts (MinPoolCost n) = "Min pool cost:" <+> prettyCookedOpt opts n
prettyTxParameterChange opts (CoinsPerUTxOByte n) = "Lovelace per utxo byte:" <+> prettyCookedOpt opts n
prettyTxParameterChange _opts (CostModels _pv1 _pv2 _pv3) = "Cost models (unsupported)"
prettyTxParameterChange opts (Prices q r) =
  prettyItemize
    "Prices:"
    "-"
    [ "Memory cost:" <+> prettyCookedOpt opts q,
      "Step cost:" <+> prettyCookedOpt opts r
    ]
prettyTxParameterChange opts (MaxTxExUnits n m) =
  prettyItemize
    "Max transaction execution units:"
    "-"
    [ "Max memory:" <+> prettyCookedOpt opts n,
      "Max steps:" <+> prettyCookedOpt opts m
    ]
prettyTxParameterChange opts (MaxBlockExUnits n m) =
  prettyItemize
    "Max block execution units:"
    "-"
    [ "Max memory:" <+> prettyCookedOpt opts n,
      "Max steps:" <+> prettyCookedOpt opts m
    ]
prettyTxParameterChange opts (MaxValSize n) = "Max value size:" <+> prettyCookedOpt opts n
prettyTxParameterChange opts (CollateralPercentage n) = "Collateral percentage:" <+> prettyCookedOpt opts n
prettyTxParameterChange opts (MaxCollateralInputs n) = "Max number of collateral inputs:" <+> prettyCookedOpt opts n
prettyTxParameterChange opts (PoolVotingThresholds a b c d e) =
  prettyItemize
    "Pool voting thresholds:"
    "-"
    [ "Motion no confidence:" <+> prettyCookedOpt opts a,
      "Committee normal:" <+> prettyCookedOpt opts b,
      "Committee no confidence:" <+> prettyCookedOpt opts c,
      "Hard fork:" <+> prettyCookedOpt opts d,
      "Security group:" <+> prettyCookedOpt opts e
    ]
prettyTxParameterChange opts (DRepVotingThresholds a b c d e f g h i j) =
  prettyItemize
    "DRep voting thresholds:"
    "-"
    [ "Motion no confidence:" <+> prettyCookedOpt opts a,
      "Committee normal:" <+> prettyCookedOpt opts b,
      "Committee no confidence:" <+> prettyCookedOpt opts c,
      "Update constitution:" <+> prettyCookedOpt opts d,
      "Hard fork initialization:" <+> prettyCookedOpt opts e,
      "Network group:" <+> prettyCookedOpt opts f,
      "Economic group:" <+> prettyCookedOpt opts g,
      "Technical group:" <+> prettyCookedOpt opts h,
      "Governance group:" <+> prettyCookedOpt opts i,
      "Treasury withdrawal:" <+> prettyCookedOpt opts j
    ]
prettyTxParameterChange opts (CommitteeMinSize n) = "Committee min size:" <+> prettyCookedOpt opts n
prettyTxParameterChange opts (CommitteeMaxTermLength n) = "Committee max term length:" <+> prettyCookedOpt opts n
prettyTxParameterChange opts (GovActionLifetime n) = "Governance action life time:" <+> prettyCookedOpt opts n
prettyTxParameterChange opts (GovActionDeposit n) = "Governance action deposit:" <+> prettyCookedOpt opts n
prettyTxParameterChange opts (DRepRegistrationDeposit n) = "DRep registration deposit:" <+> prettyCookedOpt opts n
prettyTxParameterChange opts (DRepActivity n) = "DRep activity:" <+> prettyCookedOpt opts n

prettyTxSkelRedeemer :: PrettyCookedOpts -> TxSkelRedeemer -> [DocCooked]
prettyTxSkelRedeemer opts (TxSkelRedeemer red mRefScript) =
  catMaybes
    [ case red of
        EmptyRedeemer -> Nothing
        SomeRedeemer s -> Just $ "With the following redeemer" <+> prettyCookedOpt opts s,
      ("With a reference script at:" <+>) . prettyCookedOpt opts <$> mRefScript
    ]

prettyTxSkelProposal :: PrettyCookedOpts -> TxSkelProposal -> DocCooked
prettyTxSkelProposal opts TxSkelProposal {..} =
  prettyItemizeNoTitle "-" $
    catMaybes
      [ Just $ "Governance action:" <+> prettyTxSkelGovAction opts txSkelProposalAction,
        Just $ "Return address:" <+> prettyCooked txSkelProposalAddress,
        ( \(script, redeemer) ->
            prettyItemize
              "Witness:"
              "-"
              (prettyCookedOpt opts script : prettyTxSkelRedeemer opts redeemer)
        )
          <$> txSkelProposalWitness,
        ("Anchor:" <+>) . PP.pretty <$> txSkelProposalAnchor
      ]

prettyTxSkelGovAction :: PrettyCookedOpts -> TxGovAction -> DocCooked
prettyTxSkelGovAction opts (TxGovActionParameterChange params) = prettyItemize "Parameter changes:" "-" $ prettyTxParameterChange opts <$> params
prettyTxSkelGovAction opts (TxGovActionHardForkInitiation (Api.ProtocolVersion major minor)) =
  "Protocol version:" <+> "(" <+> prettyCookedOpt opts major <+> "," <+> prettyCookedOpt opts minor <+> ")"
prettyTxSkelGovAction opts (TxGovActionTreasuryWithdrawals withdrawals) =
  prettyItemize "Withdrawals:" "-" $
    (\(cred, lv) -> prettyCookedOpt opts cred <+> "|" <+> prettyCooked (toValue lv)) <$> Map.toList withdrawals
prettyTxSkelGovAction _ TxGovActionNoConfidence = "No confidence"
prettyTxSkelGovAction opts (TxGovActionUpdateCommittee toRemoveCreds toAddCreds quorum) =
  prettyItemize
    "Updates in committee:"
    "-"
    [ prettyItemize "Credentials to remove:" "-" $
        (\(Api.ColdCommitteeCredential cred) -> prettyCookedOpt opts cred) <$> toRemoveCreds,
      prettyItemize "Credentials to add:" "-" $
        (\(Api.ColdCommitteeCredential cred, i) -> prettyCookedOpt opts cred <+> "->" <+> prettyCookedOpt opts i) <$> Map.toList toAddCreds,
      "Quorum:" <+> prettyCookedOpt opts (Api.toGHC quorum)
    ]
prettyTxSkelGovAction opts (TxGovActionNewConstitution (Api.Constitution mScriptHash)) = case mScriptHash of
  Nothing -> "Empty new constitution"
  Just sHash -> "New constitution:" <+> prettyCookedOpt opts sHash

-- | Same as the 'PrettyCooked' instance for 'Wallet' with a suffix mentioning
-- this is the balancing wallet
prettyBalancingWallet :: PrettyCookedOpts -> Wallet -> DocCooked
prettyBalancingWallet opts w =
  prettyCookedOpt opts (walletPKHash w) <+> "[Balancing]"

-- | Prints a list of pubkeys with a flag next to the balancing wallet
prettySigners :: PrettyCookedOpts -> TxOpts -> [Wallet] -> [DocCooked]
prettySigners opts TxOpts {txOptBalancingPolicy = DoNotBalance} signers = prettyCookedOpt opts . walletPKHash <$> signers
prettySigners opts TxOpts {txOptBalancingPolicy = BalanceWithFirstSigner} (firstSigner : signers) =
  prettyBalancingWallet opts firstSigner : (prettyCookedOpt opts . walletPKHash <$> signers)
prettySigners opts TxOpts {txOptBalancingPolicy = BalanceWith balancingWallet} signers =
  aux signers
  where
    aux :: [Wallet] -> [DocCooked]
    aux [] = []
    aux (s : ss)
      | s == balancingWallet = prettyBalancingWallet opts balancingWallet : aux ss
      | otherwise = prettyCookedOpt opts (walletPKHash s) : aux ss
-- The following case should never happen for real transactions
prettySigners _ _ [] = []

-- | Prints a minting specification
--
-- Examples without and with redeemer
-- > #abcdef
--     - "Foo"
--     - 500
-- > #123456
--     - "Bar"
--     - 1000
--     - "With the following redeemer: red"
--     - "With a reference at: txOutRef"
prettyMints :: PrettyCookedOpts -> (Script.Versioned Script.MintingPolicy, TxSkelRedeemer, Api.TokenName, Integer) -> DocCooked
prettyMints opts (policy, redeemer, tokenName, amount) =
  prettyItemize
    (prettyCookedOpt opts policy)
    "-"
    (PP.viaShow tokenName : PP.viaShow amount : prettyTxSkelRedeemer opts redeemer)

prettyTxSkelOut :: PrettyCookedOpts -> TxSkelOut -> DocCooked
prettyTxSkelOut opts (Pays output) =
  prettyItemize
    ("Pays to" <+> prettyCookedOpt opts (outputAddress output))
    "-"
    ( prettyCookedOpt opts (outputValue output)
        : catMaybes
          [ case outputOutputDatum output of
              Api.OutputDatum _datum ->
                Just $
                  "Datum (inlined):"
                    <+> (PP.align . prettyCookedOpt opts)
                      (output ^. outputDatumL)
              Api.OutputDatumHash _datum ->
                Just $
                  "Datum (hashed):"
                    <+> (PP.align . prettyCookedOpt opts)
                      (output ^. outputDatumL)
              Api.NoOutputDatum -> Nothing,
            getReferenceScriptDoc opts output
          ]
    )

prettyTxSkelOutDatumMaybe :: PrettyCookedOpts -> TxSkelOutDatum -> Maybe DocCooked
prettyTxSkelOutDatumMaybe _ TxSkelOutNoDatum = Nothing
prettyTxSkelOutDatumMaybe opts txSkelOutDatum@(TxSkelOutInlineDatum _) =
  Just $
    "Datum (inlined):"
      <+> PP.align (prettyCookedOpt opts txSkelOutDatum)
prettyTxSkelOutDatumMaybe opts txSkelOutDatum =
  Just $
    "Datum (hashed):"
      <+> PP.align (prettyCookedOpt opts txSkelOutDatum)

prettyTxSkelIn :: PrettyCookedOpts -> SkelContext -> (Api.TxOutRef, TxSkelRedeemer) -> DocCooked
prettyTxSkelIn opts skelContext (txOutRef, txSkelRedeemer) = do
  case lookupOutput skelContext txOutRef of
    Nothing -> "Spends" <+> prettyCookedOpt opts txOutRef <+> "(non resolved)"
    Just (output, txSkelOutDatum) ->
      prettyItemize
        ("Spends from" <+> prettyCookedOpt opts (outputAddress output))
        "-"
        ( prettyCookedOpt opts (outputValue output)
            : prettyTxSkelRedeemer opts txSkelRedeemer
              <> catMaybes
                [ prettyTxSkelOutDatumMaybe opts txSkelOutDatum,
                  getReferenceScriptDoc opts output
                ]
        )

prettyTxSkelInReference :: PrettyCookedOpts -> SkelContext -> Api.TxOutRef -> Maybe DocCooked
prettyTxSkelInReference opts skelContext txOutRef = do
  (output, txSkelOutDatum) <- lookupOutput skelContext txOutRef
  return $
    prettyItemize
      ("References output from" <+> prettyCookedOpt opts (outputAddress output))
      "-"
      ( prettyCookedOpt opts (outputValue output)
          : catMaybes
            [ prettyTxSkelOutDatumMaybe opts txSkelOutDatum,
              getReferenceScriptDoc opts output
            ]
      )

getReferenceScriptDoc :: (IsAbstractOutput output, ToScriptHash (ReferenceScriptType output)) => PrettyCookedOpts -> output -> Maybe DocCooked
getReferenceScriptDoc opts output = prettyReferenceScriptHash opts . toScriptHash <$> output ^. outputReferenceScriptL

lookupOutput :: SkelContext -> Api.TxOutRef -> Maybe (Api.TxOut, TxSkelOutDatum)
lookupOutput (SkelContext managedTxOuts managedTxSkelOutDatums) txOutRef = do
  output <- Map.lookup txOutRef managedTxOuts
  return
    ( output,
      case outputOutputDatum output of
        Api.OutputDatum datum -> Map.findWithDefault TxSkelOutNoDatum (Script.datumHash datum) managedTxSkelOutDatums
        Api.OutputDatumHash datumHash -> Map.findWithDefault TxSkelOutNoDatum datumHash managedTxSkelOutDatums
        Api.NoOutputDatum -> TxSkelOutNoDatum
    )

-- | Pretty-print a list of transaction skeleton options, only printing an
-- option if its value is non-default. If no non-default options are in the
-- list, return nothing.
mPrettyTxOpts :: PrettyCookedOpts -> TxOpts -> Maybe DocCooked
mPrettyTxOpts
  opts
  TxOpts
    { txOptEnsureMinAda,
      txOptAutoSlotIncrease,
      txOptUnsafeModTx,
      txOptBalanceOutputPolicy,
      txOptFeePolicy,
      txOptBalancingPolicy,
      txOptBalancingUtxos,
      txOptEmulatorParamsModification,
      txOptCollateralUtxos,
      txOptAnchorResolution
    } =
    prettyItemizeNonEmpty "Options:" "-" $
      catMaybes
        [ prettyIfNot def prettyEnsureMinAda txOptEnsureMinAda,
          prettyIfNot True prettyAutoSlotIncrease txOptAutoSlotIncrease,
          prettyIfNot def prettyBalanceOutputPolicy txOptBalanceOutputPolicy,
          prettyIfNot def prettyBalanceFeePolicy txOptFeePolicy,
          prettyIfNot def prettyBalancingPolicy txOptBalancingPolicy,
          prettyIfNot def prettyBalancingUtxos txOptBalancingUtxos,
          prettyIfNot [] prettyUnsafeModTx txOptUnsafeModTx,
          prettyIfNot def prettyEmulatorParamsModification txOptEmulatorParamsModification,
          prettyIfNot def prettyCollateralUtxos txOptCollateralUtxos,
          prettyIfNot def prettyAnchorResolution txOptAnchorResolution
        ]
    where
      prettyIfNot :: (Eq a) => a -> (a -> DocCooked) -> a -> Maybe DocCooked
      prettyIfNot defaultValue f x
        | x == defaultValue && not (pcOptPrintDefaultTxOpts opts) = Nothing
        | otherwise = Just $ f x
      prettyEnsureMinAda :: Bool -> DocCooked
      prettyEnsureMinAda True = "Ensure min Ada per transaction"
      prettyEnsureMinAda False = "Do not ensure min Ada per transaction"
      prettyAutoSlotIncrease :: Bool -> DocCooked
      prettyAutoSlotIncrease True = "Automatic slot increase"
      prettyAutoSlotIncrease False = "No automatic slot increase"
      prettyBalanceOutputPolicy :: BalanceOutputPolicy -> DocCooked
      prettyBalanceOutputPolicy AdjustExistingOutput = "Balance policy: Adjust existing outputs"
      prettyBalanceOutputPolicy DontAdjustExistingOutput = "Balance policy: Don't adjust existing outputs"
      prettyBalancingPolicy :: BalancingPolicy -> DocCooked
      prettyBalancingPolicy BalanceWithFirstSigner = "Balance with first signer"
      prettyBalancingPolicy (BalanceWith w) = "Balance with" <+> prettyCookedOpt opts (walletPKHash w)
      prettyBalancingPolicy DoNotBalance = "Do not balance"
      prettyUnsafeModTx :: [RawModTx] -> DocCooked
      prettyUnsafeModTx [] = "No transaction modifications"
      prettyUnsafeModTx (length -> n) = prettyCookedOpt opts n <+> "transaction" <+> PP.plural "modification" "modifications" n
      prettyEmulatorParamsModification :: Maybe EmulatorParamsModification -> DocCooked
      prettyEmulatorParamsModification Nothing = "No modifications of protocol paramters"
      prettyEmulatorParamsModification Just {} = "With modifications of protocol parameters"
      prettyCollateralUtxos :: CollateralUtxos -> DocCooked
      prettyCollateralUtxos CollateralUtxosFromBalancingWallet =
        prettyItemize "Collateral policy:" "-" ["Use value-only utxos from balancing wallet", "Send return collaterals to balancing wallet"]
      prettyCollateralUtxos (CollateralUtxosFromWallet w)
        | prettyWallet <- prettyCookedOpt opts (walletPKHash w) =
            prettyItemize "Collateral policy:" "-" ["Use value-only utxos from" <+> prettyWallet, "Send return collaterals to" <+> prettyWallet]
      prettyCollateralUtxos (CollateralUtxosFromSet txOutRefs w) =
        prettyItemize
          "Collateral policy:"
          "-"
          [ prettyItemize "Choose among the following TxOutRefs:" "-" (prettyCookedOpt opts <$> Set.toList txOutRefs),
            "Send return collaterals to" <+> prettyCookedOpt opts (walletPKHash w)
          ]
      prettyBalancingUtxos :: BalancingUtxos -> DocCooked
      prettyBalancingUtxos BalancingUtxosFromBalancingWallet = "Balance with 'only value' utxos from the balancing wallet"
      prettyBalancingUtxos (BalancingUtxosFromSet utxos) = prettyItemize "Balance with the following utxos:" "-" (prettyCookedOpt opts <$> Set.toList utxos)
      prettyBalanceFeePolicy :: FeePolicy -> DocCooked
      prettyBalanceFeePolicy AutoFeeComputation = "Use automatically computed fee"
      prettyBalanceFeePolicy (ManualFee fee) = "Use the following fee:" <+> prettyCookedOpt opts fee
      prettyAnchorResolution :: AnchorResolution -> DocCooked
      prettyAnchorResolution AnchorResolutionHttp = "Resolve anchor url with an (unsafe) http connection"
      prettyAnchorResolution (AnchorResolutionLocal urlMap) = prettyItemize "Resolve anchor url with the following table keys" "-" (PP.pretty <$> Map.keys urlMap)

-- | Pretty print a 'UtxoState'. Print the known wallets first, then unknown
-- pubkeys, then scripts.
instance PrettyCooked UtxoState where
  prettyCookedOpt opts =
    prettyItemize "UTxO state:" "•"
      . map (uncurry (prettyAddressState opts))
      . List.sortBy addressOrdering
      . Map.toList
      . utxoState
    where
      addressOrdering :: (Api.Address, a) -> (Api.Address, a) -> Ordering
      addressOrdering
        (a1@(Api.Address (Api.PubKeyCredential pkh1) _), _)
        (a2@(Api.Address (Api.PubKeyCredential pkh2) _), _) =
          case (walletPKHashToId pkh1, walletPKHashToId pkh2) of
            (Just i, Just j) -> compare i j
            (Just _, Nothing) -> LT
            (Nothing, Just _) -> GT
            (Nothing, Nothing) -> compare a1 a2
      addressOrdering
        (Api.Address (Api.PubKeyCredential _) _, _)
        (Api.Address (Api.ScriptCredential _) _, _) = LT
      addressOrdering (a1, _) (a2, _) = compare a1 a2

-- | Pretty prints the state of an address, that is the list of UTxOs (including
-- value and datum), grouped
prettyAddressState :: PrettyCookedOpts -> Api.Address -> UtxoPayloadSet -> DocCooked
prettyAddressState opts address payloadSet =
  prettyItemize
    (prettyCookedOpt opts address)
    "-"
    ( mapMaybe (prettyPayloadGrouped opts)
        . group
        . List.sortBy (compare `on` (Script.fromValue . utxoPayloadValue))
        . utxoPayloadSet
        $ payloadSet
    )
  where
    similar :: UtxoPayload -> UtxoPayload -> Bool
    similar
      (UtxoPayload _ value1 skelOutDatum1 refScript1)
      (UtxoPayload _ value2 skelOutDatum2 refScript2) =
        value1 == value2
          && skelOutDatum1 == skelOutDatum2
          && refScript1 == refScript2
    group :: [UtxoPayload] -> [[UtxoPayload]]
    group =
      case pcOptPrintTxOutRefs opts of
        PCOptTxOutRefsFull -> map (: [])
        _ -> List.groupBy similar

-- | Pretty prints payloads (datum and value corresponding to 1 UTxO) grouped
-- together when they carry same value and datum
prettyPayloadGrouped :: PrettyCookedOpts -> [UtxoPayload] -> Maybe DocCooked
prettyPayloadGrouped _ [] = Nothing
prettyPayloadGrouped opts [payload] =
  prettyPayload
    opts
    (pcOptPrintTxOutRefs opts /= PCOptTxOutRefsHidden)
    payload
prettyPayloadGrouped opts (payload : rest) =
  let cardinality = 1 + length rest
   in (PP.parens ("×" <> prettyCookedOpt opts cardinality) <+>)
        <$> prettyPayload opts False payload

prettyPayload :: PrettyCookedOpts -> Bool -> UtxoPayload -> Maybe DocCooked
prettyPayload
  opts
  showTxOutRef
  ( UtxoPayload
      { utxoPayloadTxOutRef,
        utxoPayloadValue,
        utxoPayloadSkelOutDatum,
        utxoPayloadReferenceScript
      }
    ) =
    case catMaybes
      [ if showTxOutRef
          then Just $ prettyCookedOpt opts utxoPayloadTxOutRef
          else Nothing,
        Just (prettyCookedOpt opts utxoPayloadValue),
        prettyTxSkelOutDatumMaybe opts utxoPayloadSkelOutDatum,
        prettyReferenceScriptHash opts <$> utxoPayloadReferenceScript
      ] of
      [] -> Nothing
      [doc] -> Just $ PP.align doc
      docs -> Just . PP.align . PP.vsep $ docs

prettyReferenceScriptHash :: PrettyCookedOpts -> Script.ScriptHash -> DocCooked
prettyReferenceScriptHash opts scriptHash =
  "Reference script hash:"
    <+> prettyHash (pcOptHashes opts) (toHash scriptHash)
