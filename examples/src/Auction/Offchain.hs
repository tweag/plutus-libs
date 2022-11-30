{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeApplications #-}

module Auction.Offchain where

import qualified Auction as A
import Control.Monad
import Cooked.MockChain
import Cooked.Tx.Constraints.Type
import Data.Default
import Data.Maybe
import qualified Data.Set as Set
import qualified Debug.Trace as Debug
import qualified Ledger as L
import qualified Ledger.Ada as Ada
import qualified Ledger.Index as Pl
import qualified Ledger.Interval as Interval
import qualified Ledger.Tx as Pl
import qualified Ledger.Value as Value
import Optics.Core
import qualified PlutusTx.Numeric as Pl
import qualified PlutusTx.Prelude as Pl
import Test.QuickCheck.Modifiers (NonZero (..))

-- | Make an offer. There are no checks with this transaction. Anyone is allowed
-- to pay the 'auctionValidator' with something they want to sell, using the
-- 'Offer' datum to specify the seller of the auction.
--
-- This transaction returns the 'SpendableOut' of the 'Offer' UTxO it creates.
txOffer :: MonadBlockChain m => L.Value -> Integer -> m SpendableOut
txOffer lot minBid = do
  -- oldUtxos <- scriptUtxosSuchThat A.auctionValidator (\_ _ -> True)
  seller <- ownPaymentPubKeyHash
  tx <-
    validateTxSkel $
      mempty
        { _txSkelOpts = def {adjustUnbalTx = True},
          _txSkelOuts = [paysScript A.auctionValidator (A.Offer seller minBid) lot]
        }
  outputs <- spOutsFromCardanoTx tx
  -- the transaction created exactly one script output, so the call to head never fail
  -- newUtxo : _ <- scriptUtxosSuchThat A.auctionValidator (\d x -> d Pl.== A.Offer seller minBid && x `Value.geq` lot)
  -- return $ -- Debug.trace (show tx ++ "\n\n" ++ show (Pl.getCardanoTxOutRefs tx) ++ "\n\n" ++ show (Pl.insert tx mempty)) $
  --   fst newUtxo

  -- uncomment below for something that I would expect to be equivalent, but which isn't:
  return $
    -- Debug.trace
    --   (show (fst <$> oldUtxos) ++ "\n\n" ++ show outputs ++ "\n\n" ++ show (fst <$> newUtxos))
    head $
      filter (isJust . sBelongsToScript) outputs

-- | Start an auction by setting the bidding deadline. This transaction consumes
-- the provided 'Offer' Utxo and returns a 'NoBids' UTxO to the auction
-- validator. It also mints the thread NFT that ensures the authenticity of the
-- auction from that point on.
txSetDeadline :: MonadBlockChain m => SpendableOut -> L.POSIXTime -> m Pl.CardanoTx
txSetDeadline offerUtxo deadline = do
  let lot = offerUtxo ^. spOutValue
      offerOref = offerUtxo ^. spOutTxOutRef
      theNft = A.threadToken offerOref
  (A.Offer seller minBid) <- spOutGetDatum @A.Auction offerUtxo
  validateTxSkel $
    mempty
      { _txSkelOpts = def {adjustUnbalTx = True},
        _txSkelMints =
          txSkelMintsFromList
            [ ( Pl.Versioned A.threadTokenPolicy Pl.PlutusV2,
                SomeMintsRedeemer offerOref,
                A.tokenNameFromTxOutRef offerOref,
                NonZero 1
              )
            ],
        _txSkelIns =
          Set.singleton $
            SpendsScript
              A.auctionValidator
              A.SetDeadline
              offerUtxo,
        _txSkelRequiredSigners = Set.singleton seller,
        _txSkelOuts =
          [ paysScript
              A.auctionValidator
              (A.NoBids seller minBid deadline)
              (lot <> theNft)
          ]
      }

previousBidder :: A.AuctionState -> Maybe (Integer, L.PubKeyHash)
previousBidder (A.Bidding _ _ (A.BidderInfo bid bidder)) = Just (bid, bidder)
previousBidder _ = Nothing

-- | Bid a certain amount of Lovelace on the auction with the given 'Offer'
-- UTxO. If there was a previous bidder, they will receive their money back.
txBid :: MonadBlockChain m => SpendableOut -> Integer -> m L.CardanoTx
txBid offerUtxo bid =
  let theNft = A.threadToken $ offerUtxo ^. spOutTxOutRef
   in do
        bidder <- ownPaymentPubKeyHash
        [(utxo, datum)] <-
          scriptUtxosSuchThat
            A.auctionValidator
            (\_ x -> x `Value.geq` theNft)
        -- The call to 'fromJust' can never fail. If there's already a thread token,
        -- we're at least in 'NoBids' state.
        let deadline = fromJust $ A.getBidDeadline datum
            seller = A.getSeller datum
        validateTxSkel $
          mempty
            { _txSkelOpts = def {adjustUnbalTx = True},
              _txSkelIns =
                Set.singleton $
                  SpendsScript
                    A.auctionValidator
                    (A.Bid (A.BidderInfo bid bidder))
                    utxo,
              _txSkelOuts =
                paysScript
                  A.auctionValidator
                  (A.Bidding seller deadline (A.BidderInfo bid bidder))
                  (utxo ^. spOutValue <> Ada.lovelaceValueOf bid) :
                case previousBidder datum of
                  Nothing -> []
                  Just (prevBid, prevBidder) ->
                    [paysPK prevBidder (Ada.lovelaceValueOf prevBid)],
              _txSkelValidityRange = Interval.to deadline
            }

-- | Close the auction with the given 'Offer' UTxO. If there were any bids, this
-- will pay the lot to the last bidder and the last bid to the
-- seller. Otherwise, the seller will receive the lot back. This transaction
-- also burns the thread token.
txHammer :: MonadBlockChain m => SpendableOut -> m ()
txHammer offerUtxo =
  let offerOref = offerUtxo ^. spOutTxOutRef
      theNft = A.threadToken offerOref
   in do
        utxos <-
          scriptUtxosSuchThat
            A.auctionValidator
            (\_ x -> x `Value.geq` theNft)
        (A.Offer seller _minBid) <- spOutGetDatum @A.Auction offerUtxo
        void $
          validateTxSkel $
            mempty
              { _txSkelOpts = def {adjustUnbalTx = True}
              }
              <> case utxos of
                [] ->
                  -- There's no thread token, so the auction is still in 'Offer'
                  -- state
                  mempty
                    { _txSkelIns =
                        Set.singleton $
                          SpendsScript A.auctionValidator (A.Hammer offerOref) offerUtxo,
                      _txSkelOuts =
                        [ paysPK
                            seller
                            (offerUtxo ^. spOutValue)
                        ]
                    }
                (utxo, datum) : _ ->
                  -- There is a thread token, so the auction is in 'NoBids' or
                  -- 'Bidding' state, which means that the following pattern
                  -- match can not fail:
                  let Just deadline = A.getBidDeadline datum
                   in mempty
                        { _txSkelValidityRange = Interval.from deadline,
                          _txSkelIns =
                            Set.singleton $
                              SpendsScript
                                A.auctionValidator
                                (A.Hammer offerOref)
                                utxo,
                          _txSkelMints =
                            review
                              mintsListIso
                              [ ( Pl.Versioned A.threadTokenPolicy Pl.PlutusV2,
                                  SomeMintsRedeemer $ offerUtxo ^. spOutTxOutRef,
                                  A.tokenNameFromTxOutRef offerOref,
                                  NonZero (-1)
                                )
                              ],
                          _txSkelOuts =
                            case previousBidder datum of
                              Nothing ->
                                let lot = utxo ^. spOutValue <> Pl.negate theNft
                                 in [paysPK seller lot]
                              Just (lastBid, lastBidder) ->
                                let lot =
                                      utxo ^. spOutValue
                                        <> Pl.negate (Ada.lovelaceValueOf lastBid)
                                        <> Pl.negate theNft
                                 in [ paysPK lastBidder lot,
                                      paysPK seller (Ada.lovelaceValueOf lastBid)
                                    ]
                        }

-- [SpendableOut {
--     _spOutTxOutRef = TxOutRef {txOutRefId = 1defc5b138836eecda9a023003ef86f42c4dfc02b4171c87ec0ab23b0f5bec36, txOutRefIdx = 0},
--     _spOutChainIndexTxOut =
--       ScriptChainIndexTxOut {
--         _ciTxOutAddress = Address {addressCredential = ScriptCredential 51625af2b30d3c1e83a8b006ada76dd536cdcaf7b79fd23408f7158b, addressStakingCredential = Nothing},
--         _ciTxOutValue = Value (Map [(,Map [("",1232660)]),(bca6e8ec9b55fc0044405e5a0b4142fed8bc23b9882dc7210b60ba8e,Map [("Banana",2)])]),
--         _ciTxOutScriptDatum = (43298b10672cdab78aa18d17fa349fb87e53b68a611c6ece79a51a7adcdfd150,Just (Datum {getDatum = Constr 0 [B "\162\194\fw\136z\206\FS\217\134\EM>Nu\186\189\137\147\207\213i\149\205\\\252\230\t\194",I 30000000]})),
--         _ciTxOutReferenceScript = Nothing,
--         _ciTxOutValidator = (51625af2b30d3c1e83a8b006ada76dd536cdcaf7b79fd23408f7158b,Nothing)}}]

-- tx =
--   EmulatorTx
--     { _emulatorTx =
--         Tx
--           { txInputs =
--               [ TxInput
--                   { txInputRef =
--                       TxOutRef
--                         { txOutRefId = 0769793 bdb14a22858b5be184b6205054b8810b1c3d757d85aba85408393ee29,
--                           txOutRefIdx = 65
--                         },
--                     txInputType = TxConsumePublicKeyAddress
--                   },
--                 TxInput
--                   { txInputRef =
--                       TxOutRef
--                         { txOutRefId = 0769793 bdb14a22858b5be184b6205054b8810b1c3d757d85aba85408393ee29,
--                           txOutRefIdx = 55
--                         },
--                     txInputType = TxConsumePublicKeyAddress
--                   }
--               ],
--             txReferenceInputs = [],
--             txCollateral =
--               [ TxInput
--                   { txInputRef =
--                       TxOutRef
--                         { txOutRefId = 0769793 bdb14a22858b5be184b6205054b8810b1c3d757d85aba85408393ee29,
--                           txOutRefIdx = 55
--                         },
--                     txInputType = TxConsumePublicKeyAddress
--                   }
--               ],
--             txOutputs =
--               [ TxOut
--                   { getTxOut =
--                       TxOut
--                         ( AddressInEra
--                             (ShelleyAddressInEra ShelleyBasedEraBabbage)
--                             ( ShelleyAddress
--                                 Testnet
--                                 ( ScriptHashObj
--                                     (ScriptHash "51625af2b30d3c1e83a8b006ada76dd536cdcaf7b79fd23408f7158b")
--                                 )
--                                 StakeRefNull
--                             )
--                         )
--                         ( TxOutValue
--                             MultiAssetInBabbageEra
--                             ( valueFromList
--                                 [ (AdaAssetId, 1232660),
--                                   (AssetId "bca6e8ec9b55fc0044405e5a0b4142fed8bc23b9882dc7210b60ba8e" "Banana", 2)
--                                 ]
--                             )
--                         )
--                         ( TxOutDatumInline
--                             ReferenceTxInsScriptsInlineDatumsInBabbageEra
--                             ( ScriptDataConstructor
--                                 0
--                                 [ ScriptDataBytes "\162\194\fw\136z\206\FS\217\134\EM>Nu\186\189\137\147\207\213i\149\205\\\252\230\t\194",
--                                   ScriptDataNumber 30000000
--                                 ]
--                             )
--                         )
--                         ReferenceScriptNone
--                   },
--                 TxOut
--                   { getTxOut =
--                       TxOut
--                         ( AddressInEra
--                             (ShelleyAddressInEra ShelleyBasedEraBabbage)
--                             (ShelleyAddress Testnet (KeyHashObj (KeyHash "a2c20c77887ace1cd986193e4e75babd8993cfd56995cd5cfce609c2")) StakeRefNull)
--                         )
--                         ( TxOutValue
--                             MultiAssetInBabbageEra
--                             ( valueFromList
--                                 [ (AdaAssetId, 100583887),
--                                   (AssetId "bca6e8ec9b55fc0044405e5a0b4142fed8bc23b9882dc7210b60ba8e" "Banana", 3)
--                                 ]
--                             )
--                         )
--                         TxOutDatumNone
--                         ReferenceScriptNone
--                   }
--               ],
--             txMint = Value (Map []),
--             txFee = Value (Map [(,Map [("", 183453)])]),
--             txValidRange = Interval {ivFrom = LowerBound NegInf True, ivTo = UpperBound PosInf True},
--             txMintingScripts = fromList [],
--             txWithdrawals = [],
--             txCertificates = [],
--             txSignatures =
--               fromList
--                 [ ( 8 d9de88fbf445b7f6c3875a14daba94caee2ffcbc9ac211c95aba0a2f5711853,
--                     0211 cec05bca82dd4e0787a1060eccc3fbb1e474da4c4dad2e5e3d21fe321527cc1add36d7887e0cf2e49d5d12000af7164526b1367e916a42c039d5c7f8de01
--                   )
--                 ],
--             txScripts = fromList [],
--             txData =
--               fromList
--                 [ ( 43298 b10672cdab78aa18d17fa349fb87e53b68a611c6ece79a51a7adcdfd150,
--                     Datum {getDatum = Constr 0 [B "\162\194\fw\136z\206\FS\217\134\EM>Nu\186\189\137\147\207\213i\149\205\\\252\230\t\194", I 30000000]}
--                   )
--                 ],
--             txMetadata = Nothing
--           }
--     }
