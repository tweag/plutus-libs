{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Cooked.MockChain.Monad.Staged where

import Control.Monad.Identity
import Control.Monad.Operational
import Control.Monad.Trans
import Control.Monad.Writer
import Cooked.MockChain.Monad
import Cooked.MockChain.Monad.Direct
import Cooked.MockChain.Time
import Cooked.Tx.Constraints
import qualified Data.Map as M
import qualified Ledger as Pl
import qualified PlutusTx as Pl (FromData)
import Prettyprinter (Doc, (<+>))
import qualified Prettyprinter as PP

-- | This is an initial encoding of the MockChain operations, it provides
--  a simple way of altering the AST of a trace before actually executing it.
--  On top of the operations from 'MonadMockChain' we also have 'Fail' to make
--  sure the resulting monad will be an instance of 'MonadFail'.
data MockChainOp a where
  ValidateTxSkel :: TxSkel -> MockChainOp ()
  Index :: MockChainOp (M.Map Pl.TxOutRef Pl.TxOut)
  GetSlotCounter :: MockChainOp SlotCounter
  ModifySlotCounter :: (SlotCounter -> SlotCounter) -> MockChainOp ()
  UtxosSuchThat ::
    (Pl.FromData a) =>
    Pl.Address ->
    (Maybe a -> Pl.Value -> Bool) ->
    MockChainOp [(SpendableOut, Maybe a)]
  Fail :: String -> MockChainOp a

type StagedMockChainT = ProgramT MockChainOp

type StagedMockChain = StagedMockChainT Identity

instance (Monad m) => MonadFail (StagedMockChainT m) where
  fail = singleton . Fail

instance (Monad m) => MonadMockChain (StagedMockChainT m) where
  validateTxSkel = singleton . ValidateTxSkel
  index = singleton Index
  slotCounter = singleton GetSlotCounter
  modifySlotCounter = singleton . ModifySlotCounter
  utxosSuchThat addr = singleton . UtxosSuchThat addr

-- | Interprets a single operation in the direct 'MockChainT' monad.
interpretOp :: (Monad m) => MockChainOp a -> MockChainT m a
interpretOp (ValidateTxSkel skel) = validateTxSkel skel
interpretOp Index = index
interpretOp GetSlotCounter = slotCounter
interpretOp (ModifySlotCounter f) = modifySlotCounter f
interpretOp (UtxosSuchThat addr predi) = utxosSuchThat addr predi
interpretOp (Fail str) = fail str

-- | Interprets a 'StagedMockChainT' into a 'MockChainT' computation.
interpretT :: forall m a. (Monad m) => StagedMockChainT m a -> MockChainT m a
interpretT = join . lift . fmap eval . viewT
  where
    eval :: ProgramViewT MockChainOp m a -> MockChainT m a
    eval (Return a) = return a
    eval (instr :>>= f) = interpretOp instr >>= interpretT . f

-- | Similar to interpret; but produces a description of the operations that were
--  issued to the mockchain as evaluation happens.
interpretWithDescrT ::
  forall m a.
  (Monad m) =>
  StagedMockChainT m a ->
  MockChainT (WriterT TraceDescr m) a
interpretWithDescrT = join . lift . lift . fmap eval . viewT
  where
    eval :: ProgramViewT MockChainOp m a -> MockChainT (WriterT TraceDescr m) a
    eval (Return a) = return a
    eval (instr :>>= f) =
      lift (tell $ TraceDescr $ Just $ prettyMockChainOp instr)
        >> interpretOp instr
        >>= interpretWithDescrT . f

interpretWithDescr :: forall a. StagedMockChain a -> MockChainT (Writer TraceDescr) a
interpretWithDescr = interpretWithDescrT @Identity

instance Show (MockChainOp a) where
  show _ = "<MockChainOp>"

instance Show (ProgramT f m a) where
  show _ = "<script>"

prettyMockChainOp :: MockChainOp a -> Doc ann
prettyMockChainOp (ValidateTxSkel skel) =
  PP.hang 2 $ PP.vsep ["ValidateTxSkel", prettyTxSkel skel]
prettyMockChainOp _ = "<mockchainop>"

newtype TraceDescr = TraceDescr {getDoc :: Maybe (Doc ())}

instance Show TraceDescr where
  show = maybe "" show . getDoc

instance Semigroup TraceDescr where
  TraceDescr Nothing <> y = y
  x <> TraceDescr Nothing = x
  TraceDescr (Just x) <> TraceDescr (Just y) =
    TraceDescr $ Just $ PP.vcat [x, y]

instance Monoid TraceDescr where
  mempty = TraceDescr Nothing
