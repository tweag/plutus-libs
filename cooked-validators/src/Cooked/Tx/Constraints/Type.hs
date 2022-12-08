{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE EmptyDataDeriving #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}

module Cooked.Tx.Constraints.Type where

import Control.Arrow
import qualified Control.Lens as Lens
import Cooked.MockChain.Misc
import Cooked.MockChain.Wallet (wallet, walletPKHash)
import Data.Default
import Data.Function
import Data.List
import qualified Data.List.NonEmpty as NE
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Map.NonEmpty (NEMap)
import qualified Data.Map.NonEmpty as NEMap
import Data.Maybe
import Data.Set (Set)
import qualified Data.Set as Set
import qualified Ledger as Pl hiding (validatorHash)
import qualified Ledger.Constraints as Pl
import qualified Ledger.Constraints.OffChain as Pl
import qualified Ledger.Typed.Scripts as Pl
import qualified Ledger.Value as Pl
import Optics.Core
import Optics.TH (makeLenses)
import Optics.VL (prismVL)
import qualified Plutus.V2.Ledger.Api as Pl hiding (TxOut)
import qualified PlutusTx.Prelude as Pl
import Test.QuickCheck (NonZero (..))
import Type.Reflection

-- For template Haskell reasons, the most intersting thing in this module (the
-- definition of 'TxSkel') is at the very bottom of this file

-- * 'SpendableOut': The type of UTxOs

-- | A 'SpendableOut' is an outref that is ready to be spent; with its
--  underlying 'Pl.ChainIndexTxOut'.
data SpendableOut = SpendableOut
  { _spOutTxOutRef :: Pl.TxOutRef,
    _spOutChainIndexTxOut :: Pl.ChainIndexTxOut
  }
  deriving (Eq, Show)

makeLenses ''SpendableOut

instance Ord SpendableOut where
  -- TODO: Is this sufficient, i.e. can there be well-formed 'SpendableOut's
  -- that have the same 'TxOutRef', but different 'ChainIndexTxOut's?
  (<=) = (<=) `on` (^. spOutTxOutRef)

spOutValue :: Lens' SpendableOut Pl.Value
spOutValue = spOutChainIndexTxOut % lensVL Pl.ciTxOutValue

spOutAddress :: Lens' SpendableOut Pl.Address
spOutAddress = spOutChainIndexTxOut % lensVL Pl.ciTxOutAddress

-- | If a 'SpendableOut' belongs to a public key, return its hash.
sBelongsToPubKey :: SpendableOut -> Maybe Pl.PubKeyHash
sBelongsToPubKey s = case Pl.addressCredential (s ^. spOutAddress) of
  Pl.PubKeyCredential pkh -> Just pkh
  _ -> Nothing

-- | If a 'SpendableOut' belongs to a validator, return its hash.
sBelongsToScript :: SpendableOut -> Maybe Pl.ValidatorHash
sBelongsToScript s = case Pl.addressCredential (s ^. spOutAddress) of
  Pl.ScriptCredential sh -> Just sh
  _ -> Nothing

-- | If it is a 'SpendableOut' belonging to a public key, extract datum (ot only
-- the hash), if there is one.
spOutPublicKeyDatumOrHash :: AffineTraversal' SpendableOut (Pl.DatumHash, Maybe Pl.Datum)
spOutPublicKeyDatumOrHash = spOutChainIndexTxOut % chainIndexTxOutPublicKeyDatumOrHash

chainIndexTxOutPublicKeyDatumOrHash :: AffineTraversal' Pl.ChainIndexTxOut (Pl.DatumHash, Maybe Pl.Datum)
chainIndexTxOutPublicKeyDatumOrHash = prismVL Pl._PublicKeyChainIndexTxOut % _3 % _Just

-- | If it is a 'SpendableOut' belonging to a script, extract datum (or only the
-- hash).
spOutScriptDatumOrHash :: AffineTraversal' SpendableOut (Pl.DatumHash, Maybe Pl.Datum)
spOutScriptDatumOrHash = spOutChainIndexTxOut % chainIndexTxOutScriptDatumOrHash

chainIndexTxOutScriptDatumOrHash :: AffineTraversal' Pl.ChainIndexTxOut (Pl.DatumHash, Maybe Pl.Datum)
chainIndexTxOutScriptDatumOrHash = prismVL Pl._ScriptChainIndexTxOut % _3

chainIndexTxOutDatumOrHash :: AffineTraversal' Pl.ChainIndexTxOut (Pl.DatumHash, Maybe Pl.Datum)
chainIndexTxOutDatumOrHash = unsafeOr chainIndexTxOutPublicKeyDatumOrHash chainIndexTxOutScriptDatumOrHash
  where
    -- In the best of all possible worlds, I'd write this:
    -- > unsafeOr = singular . adjoin
    -- Alas, @adjoin@ only is available in optics-core >= 0.4, which we can not
    -- use at the moment, because of the compiler and cabal versions from IOHK
    -- that we use (at least that is what I think is going on). TODO: can we change this?
    unsafeOr ::
      (Is k An_AffineTraversal, Is l An_AffineTraversal) =>
      Optic' k is s a ->
      Optic' l js s a ->
      AffineTraversal' s a
    unsafeOr o1 o2 = withAffineTraversal o1 $ \m1 u1 ->
      withAffineTraversal o2 $ \m2 u2 ->
        atraversal
          ( \s -> case m1 s of
              Left _ -> case m2 s of
                Left _ -> Left s
                Right a -> Right a
              Right a -> Right a
          )
          (\s a -> u2 (u1 s a) a)

-- | Extract datum (or only the hash), if there is one
spOutDatumOrHash :: AffineTraversal' SpendableOut (Pl.DatumHash, Maybe Pl.Datum)
spOutDatumOrHash = spOutChainIndexTxOut % chainIndexTxOutDatumOrHash

spOutDatumHash :: SpendableOut -> Maybe Pl.DatumHash
spOutDatumHash = (^? spOutDatumOrHash % _1)

spOutDatum :: SpendableOut -> Maybe Pl.Datum
spOutDatum = (^? spOutDatumOrHash % _2 % _Just)

-- | The 'TxOut' corresponding to a 'SpendableOut'
spOutTxOut :: SpendableOut -> Pl.TxOut
spOutTxOut spOut =
  toPlTxOut
    (spOut ^. spOutAddress)
    (spOut ^. spOutValue)
    (spOut ^? spOutDatumOrHash % _2 % _Just)

-- * Transaction labels

type LabelConstrs x = (Show x, Typeable x, Eq x, Ord x)

data TxLabel where
  TxLabel :: LabelConstrs x => x -> TxLabel

instance Eq TxLabel where
  a == x = compare a x == EQ

instance Show TxLabel where
  show (TxLabel x) = show x

{- note: How to write 'Ord' instances for types with existential type variables in
 their constructors?

The idea of the 'Ord' instances for 'TxLabel', 'MintsConstraint', and
'InConstraint' is illustrated by the instance for 'TxLabel' below: Sort by the
type representation of the existential type variable first, and then by the
concrete value within each of the possible instances of the existential.

This means:

- If the type(representation) of a is strictly smaller than the type of b, then
  a<b.

- If the types of a and b are the same, compare a and b normally.

- If the type of a is strictly greater than the type of b, then a>b.

-}

instance Ord TxLabel where
  compare (TxLabel a) (TxLabel x) =
    case compare (SomeTypeRep (typeOf a)) (SomeTypeRep (typeOf x)) of
      LT -> LT
      GT -> GT
      EQ -> case typeOf a `eqTypeRep` typeOf x of
        Just HRefl -> compare a x
        -- This can never happen, since 'eqTypeRep' is implemented in terms of
        -- '==' on the type representation:
        Nothing -> error "Type representations compare as EQ, but are not eqTypeRep"

-- * Transaction options

-- | Specifies how to select the collateral input
data Collateral
  = -- | Will select the first Ada-only UTxO we find belonging to 'ownPaymentPubKeyHash'
    CollateralAuto
  | -- | Will use the 'Pl.TxOutRef's given in the set. The set can be empty, in
    --  which case no collateral will be used whatsoever.
    CollateralUtxos (Set Pl.TxOutRef)
  deriving (Eq, Show)

instance Default Collateral where
  def = CollateralAuto

-- | Any manual adjustment should be kept, and if there are several sets of
-- potential collateral UTxOs, they should combine.
instance Semigroup Collateral where
  CollateralAuto <> a = a
  a <> CollateralAuto = a
  CollateralUtxos l <> CollateralUtxos r = CollateralUtxos (l <> r)

instance Monoid Collateral where
  mempty = def

-- | Whether to adjust existing public key outputs during transaction
-- balancing. TODO: Why do we need these two options? Are they just historical
-- baggage?
data BalanceOutputPolicy
  = -- | Try to adjust an existing public key output with the change. If no
    --   suitable output can be found, create a new change output.
    AdjustExistingOutput
  | -- | Do not change the existing outputs, always create a new change
    --   output.
    DontAdjustExistingOutput
  deriving (Eq, Ord, Show)

instance Default BalanceOutputPolicy where
  def = AdjustExistingOutput

-- | This instance always takes the non-default value, if either of the
-- arguments is non-default.
instance Semigroup BalanceOutputPolicy where
  a <> b = fromMaybe def (find (/= def) [a, b])

instance Monoid BalanceOutputPolicy where
  mempty = def

-- | Wraps a function that can be applied to a transaction right before submitting it.
--  We have a distinguished datatype to be able to provide a little more info on
--  the show instance.
data RawModTx
  = -- | Apply modification on transaction after balancing is performed
    RawModTxAfterBalancing (Pl.Tx -> Pl.Tx)
  | -- | Apply modification on transaction before balancing and transaction fee computation
    --   are performed.
    RawModTxBeforeBalancing (Pl.Tx -> Pl.Tx)

instance Eq RawModTx where
  _ == _ = False

instance Show RawModTx where
  show (RawModTxAfterBalancing _) = "RawModTxAfterBalancing"
  show (RawModTxBeforeBalancing _) = "RawModTxBeforeBalancing"

-- | only applies modification for RawModTxAfterBalancing
applyRawModOnBalancedTx :: [RawModTx] -> Pl.Tx -> Pl.Tx
applyRawModOnBalancedTx [] tx = tx
applyRawModOnBalancedTx (RawModTxAfterBalancing f : fs) tx = applyRawModOnBalancedTx fs . f $ tx
applyRawModOnBalancedTx (RawModTxBeforeBalancing _ : fs) tx = applyRawModOnBalancedTx fs tx

-- | only applies modification for RawModTxBeforeBalancing
applyRawModOnUnbalancedTx :: [RawModTx] -> Pl.UnbalancedTx -> Pl.UnbalancedTx
applyRawModOnUnbalancedTx [] tx = tx
applyRawModOnUnbalancedTx (RawModTxAfterBalancing _ : fs) tx = applyRawModOnUnbalancedTx fs tx
applyRawModOnUnbalancedTx (RawModTxBeforeBalancing f : fs) tx = applyRawModOnUnbalancedTx fs . (Pl.tx Lens.%~ f) $ tx

-- | Set of options to modify the behavior of generating and validating some transaction. Some of these
-- options only have an effect when running in the 'Plutus.Contract.Contract', some only have an effect when
-- running in 'MockChainT'. If nothing is explicitely stated, the option has an effect independently of the
-- running context.
--
-- IMPORTANT INTERNAL: If you add or remove fields from 'TxOpts', make sure
-- to update the internal @fields@ value from 'Cooked.Tx.Constraints.Pretty'
data TxOpts = TxOpts
  { -- | Performs an adjustment to unbalanced txs, making sure every UTxO that is produced
    --  has the necessary minimum amount of Ada.
    --
    -- By default, this is set to @False@, given this is the default behavior in Plutus:
    -- https://github.com/input-output-hk/plutus-apps/issues/143#issuecomment-1013012744
    adjustUnbalTx :: Bool,
    -- | When submitting a transaction for real (i.e., running in the 'Plutus.Contract.Contract' monad),
    --  it is common to call 'Plutus.Contract.Request.awaitTxConfirmed' after 'Plutus.Contract.Request.submitTxConstraints'.
    --  If you /do NOT/ wish to do so, please set this to @False@.
    --
    --  /This has NO effect when running outside of 'Plutus.Contract.Contract'/.
    --  By default, this is set to @True@.
    awaitTxConfirmed :: Bool,
    -- | Whether to increase the slot counter automatically on this submission.
    -- This is useful for modelling transactions that could be submitted in parallel in reality, so there
    -- should be no explicit ordering of what comes first. One good example is in the Crowdfunding use case contract.
    --
    -- /This has NO effect when running in 'Plutus.Contract.Contract'/.
    --  By default, this is set to @True@.
    autoSlotIncrease :: Bool,
    -- | Reorders the transaction outputs to fit the ordering of output
    -- constraints. Those outputs are put at the very beginning of the list.
    -- /This has NO effect when running in 'Plutus.Contract.Contract'/.
    --  By default, this is set to @True@.
    forceOutputOrdering :: Bool,
    -- | Applies an arbitrary modification to a transaction after it has been
    -- potentially adjusted ('adjustUnbalTx') and balanced. This is prefixed
    -- with /unsafe/ to draw attention to the fact that modifying a transaction
    -- at that stage might make it invalid. Still, this offers a hook for being
    -- able to alter a transaction in unforeseen ways. It is mostly used to test
    -- contracts that have been written for custom PABs.
    --
    -- One interesting use of this function is to observe a transaction just
    -- before it is being sent for validation, with @unsafeModTx =
    -- [RawModTxAfterBalancing Debug.Trace.traceShowId]@.
    --
    -- /This has NO effect when running in 'Plutus.Contract.Contract'/.  By
    -- default, this is set to 'Id'.
    unsafeModTx :: [RawModTx],
    -- | Whether to balance the transaction or not. Balancing is the process of ensuring that
    --  @input + mint = output + fees@, if you decide to set @balance = false@ you will have trouble
    -- satisfying that equation by hand because @fees@ are variable. You will likely see a @ValueNotPreserved@ error
    -- and should adjust the fees accordingly. For now, there is no option to skip the fee computation because
    -- without it, validation through "Ledger.Validation" would fail with @InsufficientFees@.
    --
    -- /This has NO effect when running in 'Plutus.Contract.Contract'/.
    -- By default, this is set to @True@.
    balance :: Bool,
    -- | Which collateral utxo to use for this transaction. A collateral UTxO must be an Ada-only utxo
    -- and can be specified manually, or it can be chosen automatically, if any is available.
    --
    -- /This has NO effect when running in 'Plutus.Contract.Contract'/.
    -- By default, this is set to @CollateralAuto@.
    collateral :: Collateral,
    -- | The 'BalanceOutputPolicy' to apply when balancing the transaction.
    --
    -- /This has NO effect when running in 'Plutus.Contract.Contract'/.
    -- By default, this is set to @AdjustExistingOutput@.
    balanceOutputPolicy :: BalanceOutputPolicy
  }
  deriving (Eq, Show)

instance Default TxOpts where
  def =
    TxOpts
      { adjustUnbalTx = False,
        awaitTxConfirmed = True,
        autoSlotIncrease = True,
        forceOutputOrdering = True,
        unsafeModTx = [],
        balance = True,
        collateral = def,
        balanceOutputPolicy = def
      }

-- | This instance always takes the non-default value on booleans, if either of
-- the arguments is non-default.
instance Semigroup TxOpts where
  ( TxOpts
      adjustUnbalTx1
      awaitTxConfirmed1
      autoSlotIncrease1
      forceOutputOrdering1
      unsafeModTx1
      balance1
      collateral1
      balanceOutputPolicy1
    )
    <> ( TxOpts
           adjustUnbalTx2
           awaitTxConfirmed2
           autoSlotIncrease2
           forceOutputOrdering2
           unsafeModTx2
           balance2
           collateral2
           balanceOutputPolicy2
         ) =
      TxOpts
        (takeNonDefault (adjustUnbalTx def) adjustUnbalTx1 adjustUnbalTx2)
        (takeNonDefault (awaitTxConfirmed def) awaitTxConfirmed1 awaitTxConfirmed2)
        (takeNonDefault (autoSlotIncrease def) autoSlotIncrease1 autoSlotIncrease2)
        (takeNonDefault (forceOutputOrdering def) forceOutputOrdering1 forceOutputOrdering2)
        (unsafeModTx1 ++ unsafeModTx2) -- this will apply the left modifications first. See the definitions of 'applyRawModOnUnbalancedTx' and 'applyRawModOnBalancedTx'
        (takeNonDefault (balance def) balance1 balance2)
        (collateral1 <> collateral2)
        (balanceOutputPolicy1 <> balanceOutputPolicy2)
      where
        takeNonDefault d a b = if any (/= d) [a, b] then not d else d

instance Monoid TxOpts where
  mempty = def

-- * Description of the Minting

type MintsConstrs a =
  ( Pl.ToData a,
    Show a,
    Typeable a
  )

data MintsRedeemer where
  NoMintsRedeemer :: MintsRedeemer
  SomeMintsRedeemer :: MintsConstrs a => a -> MintsRedeemer

instance Show MintsRedeemer where
  show NoMintsRedeemer = "NoMintsRedeemer"
  show (SomeMintsRedeemer x) = "(SomeMintsRedeemer " ++ show x ++ ")"

instance Eq MintsRedeemer where
  a == b = compare a b == EQ

instance Ord MintsRedeemer where
  compare NoMintsRedeemer NoMintsRedeemer = EQ
  -- The next two clauses are ugly, but necessary, since minting with no
  -- redeemer is represented as minting with the unit redeemer on-chain.
  compare NoMintsRedeemer (SomeMintsRedeemer a) =
    if Pl.unitRedeemer == Pl.Redeemer (Pl.toBuiltinData a)
      then EQ
      else LT
  compare (SomeMintsRedeemer a) NoMintsRedeemer =
    if Pl.unitRedeemer == Pl.Redeemer (Pl.toBuiltinData a)
      then EQ
      else GT
  compare (SomeMintsRedeemer a) (SomeMintsRedeemer b) =
    case compare (SomeTypeRep $ typeOf a) (SomeTypeRep $ typeOf b) of
      LT -> LT
      GT -> GT
      EQ -> case typeOf a `eqTypeRep` typeOf b of
        Just HRefl -> compare (Pl.toData a) (Pl.toData b)
        Nothing -> error "Type representations compare as EQ, but are not eqTypeRep"

-- | A description of what a transaction mints: For every policy, there can only
-- be one redeemer, and if there is a redeemer, there mus be some token names,
-- each with a non-zero amount of tokens.
type TxSkelMints =
  Map
    (Pl.Versioned Pl.MintingPolicy)
    (MintsRedeemer, NEMap Pl.TokenName (NonZero Integer))

-- | Combining 'TxSkelMints' in a sensible way. In particular, this means that
--
-- > Map.fromList [(pol, (red, NEMap.fromList [(tName, 1)]))]
--
-- and
--
-- > Map.fromList [(pol, (red, NEMap.fromList [(tName, -1)]))]
--
-- will combine to become the empty 'TxSkelMints' (and similar examples, where
-- the values add up to zero, see the comment at the definition of
-- 'addToTxSkelMints').
instance {-# OVERLAPPING #-} Semigroup TxSkelMints where
  a <> b =
    foldl
      (flip addToTxSkelMints)
      a
      (txSkelMintsToList b)

instance {-# OVERLAPPING #-} Monoid TxSkelMints where
  mempty = Map.empty

-- | Add a new entry to a 'TxSkelMints'. There are a few wrinkles:
--
-- (1) If for a given policy, redeemer, and token name, there are @n@ tokens in
-- the argument 'TxSkelMints', and you add @-n@ tokens, the corresponding entry
-- in the "inner map" of the policy will disappear (obviously, because all of
-- its values have to be non-zero). If that also means that the inner map
-- becomes empty, the policy will disappear from the 'TxSkelMints' altogether.
--
-- (2) If a policy is already present on the argument 'TxSkelMints' with a
-- redeemer @a@, and you add a mint with a different redeemer @b@, the old
-- redeemer is thrown away. This is because, on the plutus-apps 'Tx' type, every
-- minting policy can have only one redeemer per transaction. The values
-- associated with the token names of that policy are added as described above,
-- though. This means that any pre-exixting values will be minted with a new
-- redeemer.
--
-- If, for some reason, you really want to generate a 'TxSkelMints' that has
-- both a negative and a positive entry of the same asset class and redeemer,
-- you'll have to do so manually. Note, however, that even if you do so, NO
-- VALIDATOR OR MINTING POLICY WILL EVER GET TO SEE A TRANSACTION WITH SUCH
-- CONFLICTING INFORMATION. This is not a design decision/limitation of
-- cooked-validators: The 'Tx' type has _one field_ for the minted value. This
-- means that there is no way to preserve such information.
addToTxSkelMints ::
  (Pl.Versioned Pl.MintingPolicy, MintsRedeemer, Pl.TokenName, NonZero Integer) ->
  TxSkelMints ->
  TxSkelMints
addToTxSkelMints (pol, red, tName, NonZero amount) mints =
  case mints Map.!? pol of
    Nothing ->
      -- The policy isn't yet in the given 'TxSkelMints', so we can just add a
      -- new entry:
      Map.insert pol (red, NEMap.singleton tName (NonZero amount)) mints
    Just (_oldRed, innerMap) ->
      -- Ignore the old redeemer: If it's the same as the new one, nothing will
      -- change, if not, the new redeemer will be kept.
      case innerMap NEMap.!? tName of
        Nothing ->
          -- The given token name has not yet occurred for the given
          -- policy. This means that we can just add the new tokens to the
          -- inner map:
          Map.insert pol (red, NEMap.insert tName (NonZero amount) innerMap) mints
        Just (NonZero oldAmount) ->
          let newAmount = oldAmount + amount
           in if newAmount /= 0
                then -- If the sum of the old amount of tokens and the additional
                -- tokens is non-zero, we can just update the amount in the
                -- inner map:
                  Map.insert pol (red, NEMap.insert tName (NonZero newAmount) innerMap) mints
                else -- If the sum is zero, we'll have to delete the token name
                -- from the inner map. If that yields a completely empty
                -- inner map, we'll have to remove the entry altogether:
                case NEMap.nonEmptyMap $ NEMap.delete tName innerMap of
                  Nothing -> Map.delete pol mints
                  Just newInnerMap -> Map.insert pol (red, newInnerMap) mints

txSkelMintsToList :: TxSkelMints -> [(Pl.Versioned Pl.MintingPolicy, MintsRedeemer, Pl.TokenName, NonZero Integer)]
txSkelMintsToList =
  concatMap
    ( \(p, (r, m)) ->
        (\(t, n) -> (p, r, t, n))
          <$> NE.toList (NEMap.toList m)
    )
    . Map.toList

-- | This function relies on the 'Monoid' instance of 'TxSkelMints'. So, some
-- non-empty lists (where all amounts for a given asset class an redeemer add up
-- to zero) might be translated into the empty 'TxSkelMints'. (See the comment
-- at the 'Semigroup' instance definition of 'TxSkelMints', and at the
-- definition of 'addToTxSkelMints'.)
txSkelMintsFromList :: [(Pl.Versioned Pl.MintingPolicy, MintsRedeemer, Pl.TokenName, NonZero Integer)] -> TxSkelMints
txSkelMintsFromList =
  foldMap
    ( \(policy, red, tName, amount) ->
        Map.singleton policy (red, NEMap.singleton tName amount)
    )

-- | Convert between 'TxSkelMints' and a list of tuples describing eveything
-- that's being minted. This is implemented in terms of 'txSkelMintsFromList'
-- (see the comment at that function). The upshot is that
--
-- > review mintsListIso . view mintsListIso
--
-- is the identity on 'TxSkelMints', but
--
-- > view mintsListIso . review mintsListIso
--
-- is NOT THE IDENTITY on @[(Pl.MintingPolicy, MintsRedeemer, Pl.TokenName,
-- NonZero Integer)]@.
mintsListIso :: Iso' TxSkelMints [(Pl.Versioned Pl.MintingPolicy, MintsRedeemer, Pl.TokenName, NonZero Integer)]
mintsListIso = iso txSkelMintsToList txSkelMintsFromList

-- | The value described by a 'TxSkelMints'
txSkelMintsValue :: TxSkelMints -> Pl.Value
txSkelMintsValue =
  foldMapOf
    (mintsListIso % folded)
    ( \(policy, _, tName, NonZero amount) ->
        Pl.assetClassValue
          ( Pl.assetClass
              (Pl.scriptCurrencySymbol policy)
              tName
          )
          amount
    )

-- * Input Constraints

type SpendsScriptConstrs a =
  ( -- Pl.ToData (Pl.DatumType a),
    Pl.ToData (Pl.RedeemerType a),
    Pl.UnsafeFromData (Pl.DatumType a),
    Show (Pl.DatumType a),
    Show (Pl.RedeemerType a),
    -- Pl.Eq (Pl.DatumType a),
    Pl.Eq (Pl.RedeemerType a),
    Typeable a
  )

data InConstraint where
  SpendsScript ::
    SpendsScriptConstrs a =>
    { _spendingValidator :: Pl.TypedValidator a,
      _redeemer :: Pl.RedeemerType a,
      _input :: SpendableOut
    } ->
    InConstraint
  SpendsPK :: {_input :: SpendableOut} -> InConstraint

deriving instance Show InConstraint

makeLenses ''InConstraint

instance Eq InConstraint where
  s1 == s2 = compare s1 s2 == EQ

instance Ord InConstraint where
  compare (SpendsScript v1 r1 o1) (SpendsScript v2 r2 o2) =
    case compare (SomeTypeRep (typeOf v1)) (SomeTypeRep (typeOf v2)) of
      LT -> LT
      GT -> GT
      EQ -> case typeOf v1 `eqTypeRep` typeOf v2 of
        Just HRefl ->
          -- TODO will this suffice, or do we need to compare more components of
          -- the typed validator?
          compare
            (Pl.validatorHash v1, Pl.toData r1, o1)
            (Pl.validatorHash v2, Pl.toData r2, o2)
        Nothing -> error "Type representations compare as EQ, but are not eqTypeRep"
  compare (SpendsPK o1) (SpendsPK o2) = compare o1 o2
  compare SpendsPK {} SpendsScript {} = LT
  compare SpendsScript {} SpendsPK {} = GT

-- * Output Constraints

type PaysScriptConstrs a =
  ( Pl.ToData (Pl.DatumType a),
    Show (Pl.DatumType a),
    Pl.Eq (Pl.DatumType a),
    Typeable a
  )

type PaysPKConstrs a =
  ( Pl.ToData a,
    Show a,
    Pl.Eq a,
    Typeable a
  )

data OutConstraint where
  PaysScript ::
    PaysScriptConstrs a =>
    { _recipientValidator :: Pl.TypedValidator a,
      _mStakeCred :: Maybe Pl.StakingCredential,
      _paysScriptDatum :: Pl.DatumType a,
      _outValue :: Pl.Value
    } ->
    OutConstraint
  PaysPK ::
    PaysPKConstrs a =>
    { _recipientPubKeyHash :: Pl.PubKeyHash,
      _mStakePubKeyHash :: Maybe Pl.StakePubKeyHash,
      _paysPKDatum :: Maybe a,
      _outValue :: Pl.Value
    } ->
    OutConstraint

deriving instance Show OutConstraint

makeLenses ''OutConstraint

outConstraintDatum :: AffineFold OutConstraint Pl.Datum
outConstraintDatum =
  afolding
    ( \case
        PaysScript {_paysScriptDatum = datum} -> Just . Pl.Datum . Pl.toBuiltinData $ datum
        PaysPK {_paysPKDatum = Just datum} -> Just . Pl.Datum . Pl.toBuiltinData $ datum
        _ -> Nothing
    )

recipientAddress :: OutConstraint -> Pl.Address
recipientAddress PaysScript {_recipientValidator = val} = Pl.validatorAddress val
recipientAddress PaysPK {_recipientPubKeyHash = pkh} =
  -- Should/Can we use the '_mStakpkhbKeyHash' here, to generate a staking
  -- credential? TODO
  Pl.Address (Pl.PubKeyCredential pkh) Nothing

instance Eq OutConstraint where
  (PaysScript v1 sc1 d1 x1) == (PaysScript v2 sc2 d2 x2) =
    case typeOf v1 `eqTypeRep` typeOf v2 of
      Just HRefl -> d1 Pl.== d2 && (v1, sc1, x1) == (v2, sc2, x2)
      Nothing -> False
  (PaysPK h1 sc1 d1 x1) == (PaysPK h2 sc2 d2 x2) =
    case typeOf d1 `eqTypeRep` typeOf d2 of
      Just HRefl -> d1 Pl.== d2 && (h1, sc1, x1) == (h2, sc2, x2)
      Nothing -> False
  _ == _ = False

paysPK :: Pl.PubKeyHash -> Pl.Value -> OutConstraint
paysPK pkh = PaysPK @() pkh Nothing Nothing

paysScript :: (PaysScriptConstrs a) => Pl.TypedValidator a -> Pl.DatumType a -> Pl.Value -> OutConstraint
paysScript tv = PaysScript tv Nothing

-- * Transaction skeletons

data TxSkel where
  TxSkel ::
    { _txSkelLabel :: Set TxLabel,
      _txSkelOpts :: TxOpts,
      _txSkelMints :: TxSkelMints,
      _txSkelValidityRange :: Pl.POSIXTimeRange,
      _txSkelRequiredSigners :: Set Pl.PubKeyHash,
      _txSkelIns :: Set InConstraint,
      _txSkelInsCollateral :: Set SpendableOut,
      _txSkelOuts :: [OutConstraint],
      _txSkelFee :: Pl.Value
    } ->
    TxSkel
  -- This equality instance should reflect semantic equality; If two 'TxSkel's
  -- are equal in the sense of '==', they specify the same transaction(s).
  deriving (Show, Eq)

makeLenses ''TxSkel

-- | The idea behind this 'Semigroup' instance is that for two 'TxSkel's @a@ and
-- @b@, the transaction(s) described by @a <> b@ should satisfy all requirements
-- contained in @a@ and all requirements contained in @b@. There are a few
-- wrinkles with regard to this:
--
-- - commutativity: @a <> b@ and @b <> a@ describe different transactions in
--   general. In particular,
--
--   - The output constraints of the right argument are appended to the end of
--     the list of transaction outputs. This matters because some transactions
--     rely on the ordering of outputs.
--
--   - The 'unsafeModTx' contained in the '_txSkelOpts' is also combined
--     non-commutatively. The modifications in the left argument will be applied
--     first.
--
-- - preference for non-defaults: All of the boolean options in '_txSkelOpts',
--   as well as 'collateral' and 'balanceOutputPolicy' combine in a way that if
--   either of the arguments has a non-default value, that value will be
--   kept. In the case of 'collateral', the sets of Collateral UTxOs will be
--   combined (see the 'Semigroup' definitions for 'Collateral' and
--   'BalanceOutputPolicy').
--
-- One property that should hold (TODO: write tests) is that
--
-- > a == x && b == y `implies` a <> b == x <> y
instance Semigroup TxSkel where
  (TxSkel l1 p1 m1 r1 s1 i1 c1 o1 f1) <> (TxSkel l2 p2 m2 r2 s2 i2 c2 o2 f2) =
    TxSkel
      (l1 <> l2)
      (p1 <> p2)
      (m1 <> m2)
      (r1 `Pl.intersection` r2)
      (s1 <> s2)
      (i1 <> i2)
      (c1 <> c2)
      (o1 ++ o2)
      (f1 <> f2)

instance Monoid TxSkel where
  mempty = TxSkel
    { _txSkelLabel = Set.empty,
      _txSkelOpts = mempty,
      _txSkelMints = Map.empty,
      _txSkelValidityRange = Pl.always,
      _txSkelRequiredSigners = Set.singleton $ walletPKHash $ wallet 1,
      _txSkelIns = Set.empty,
      _txSkelInsCollateral = Set.empty,
      _txSkelOuts = [],
      _txSkelFee = mempty
    }

-- | All data on the given 'TxSkel', with their hashes
txSkelData :: TxSkel -> Map Pl.DatumHash Pl.Datum
txSkelData sk = txSkelInputData sk <> txSkelOutputData sk

txSkelInputData :: TxSkel -> Map Pl.DatumHash Pl.Datum
txSkelInputData =
  foldMapOf
    (txSkelIns % folded % input % spOutDatumOrHash)
    ( \(datumHash, mDatum) ->
        case mDatum of
          Nothing -> Map.empty
          Just datum -> Map.singleton datumHash datum
    )

txSkelInputDatumHashes :: TxSkel -> [Pl.DatumHash]
txSkelInputDatumHashes =
  foldMapOf
    (txSkelIns % folded % input % spOutDatumOrHash % _1)
    (: [])

txSkelOutputData :: TxSkel -> Map Pl.DatumHash Pl.Datum
txSkelOutputData =
  foldMapOf
    (txSkelOuts % folded % outConstraintDatum)
    (\datum -> Map.singleton (Pl.datumHash datum) datum)

-- | All 'TxOutRefs' of transaction inputs, resolved.
txSkelUtxoIndex :: TxSkel -> Map Pl.TxOutRef Pl.TxOut
txSkelUtxoIndex =
  foldMapOf
    (txSkelIns % folded % input)
    ( \spOut ->
        Map.singleton
          (spOut ^. spOutTxOutRef)
          (spOutTxOut spOut)
    )

-- | The value in all transaction inputs, plus the positive part of the minted
-- value. This is the left hand side of the "balancing equation":
--
-- > mints + inputs = fees + burns + outputs
txSkelInputValue :: TxSkel -> Pl.Value
txSkelInputValue skel@TxSkel {_txSkelMints = mints} =
  positivePart (txSkelMintsValue mints)
    <> foldOf (txSkelIns % folded % input % spOutValue) skel

-- | The value in all transaction inputs, plus the negative parts of the minted
-- value. This is the right hand side of the "balancing equation":
--
-- > mints + inputs = fees + burns + outputs
txSkelOutputValue :: TxSkel -> Pl.Value
txSkelOutputValue skel@TxSkel {_txSkelMints = mints} =
  negativePart (txSkelMintsValue mints)
    <> foldOf (txSkelOuts % folded % outValue) skel
    <> skel ^. txSkelFee

flattenValueI :: Iso' Pl.Value [(Pl.AssetClass, Integer)]
flattenValueI =
  iso
    (map (\(cSymbol, tName, amount) -> (Pl.assetClass cSymbol tName, amount)) . Pl.flattenValue)
    (foldl' (\v (ac, amount) -> v <> Pl.assetClassValue ac amount) mempty)

-- | The positive part of a value. For every asset class in the given value,
-- this asset class and its amount are included in the output iff the amount is
-- strictly positive. It holds
--
-- > x == positivePart x <> Pl.negate negativePart x
positivePart :: Pl.Value -> Pl.Value
positivePart = over flattenValueI (filter $ (0 <) . snd)

-- | The negative part of a value. For every asset class in the given value,
-- this asset class and its negated amount are included in the output iff the
-- amount is strictly negative. It holds
--
-- > x == positivePart x <> Pl.negate negativePart x
negativePart :: Pl.Value -> Pl.Value
negativePart = over flattenValueI (mapMaybe (\(ac, n) -> if n < 0 then Just (ac, - n) else Nothing))
