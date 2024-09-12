# Cheatsheet

* This cheastsheet is quick reminder, not a tutorial about `cooked-validators`.
* Minimum prior knowledge (Cardano, general idea of what `cooked-validators` is about) is expected.
* It reminds how to use or help discover `cooked-validators` features.
* Code snippets are not usable as is, they give intuition and direction. Adapt them to your use case.

## Basics

### Run a trace

* In a test
    * `Tasty.testCase "foo" $ C.testSucceeds foo`
    * `Tasty.testCase "foo" $ C.testFails foo`
* In the REPL
    * `printCooked $ interpretAndRun foo` for all traces
    * `printCooked $ runMockChain foo` for `MonadBlockChain` traces only

### Custom initial distributions of UTxOs

#### Creation

* With values only
  ```haskell
  initDist :: InitialDistribution
  initDist = distributionFromList $
	  [ (wallet 1 , [ ada 42 , ada 2 <> quickValue "TOK" 1 ]
	  , (wallet 2 , [ ada 10 ])
	  , (wallet 3 , [ ada 10 <> permanentValue "XYZ" 10])
	  ]
  ```
* With arbitrary payments
  ```haskell
  initDist :: InitialDistribution
  initDist = InitialDistribution
	[ paysPK (wallet 3) (ada 6)
    , paysScript fooTypedValidator FooTypedDatum (ada 6)
	, paysPK (wallet 2) (ada 2) `withDatum` fooDatum
	, paysPK (wallet 1) (ada 2) `withReferenceScript` fooValidator
	]
  ```
* Ensure each initial distribution payment has min ada
  ```haskell
  initDist :: InitialDistribution
  initDist = unsafeToInitDistWithMinAda $ InitialDistribution ...
  ```
#### Usage

* In a test `Tasty.testCase "foo" $ testSucceedsFrom def initDist foo`
* In the REPL `printCooked $ interpretAndRunWith (runMockChainTFrom initDist) foo`

### Give human-readable names to pubkey/script/minting hashes

```haskell
pcOpts :: C.PrettyCookedOpts
pcOpts =
  def
    { C.pcOptHashes =
        def
          { C.pcOptHashNames =
                C.hashNamesFromList
                  [ (alice, "Alice"),
                    (bob, "Bob"),
                    (carrie, "Carie")
                  ]
                <> C.hashNamesFromList
                  [ (nftCurrencySymbol, "NFT"),
                    (customCoinsCurrencySymbol, "Custom Coins")
                  ]
                <> C.hashNamesFromList
                  [ (fooValidator, "Foo")
                  ]
                <> C.defaultHashNames -- IMPORTANT: must be the last element
          }
    }
```

### Write a trace or endpoint

```haskell
foo :: MonadBlockChain m => m ()
foo = do
    transactionOrEndpoint1
    transactionOrEndpoint2
    transactionOrEndpoint3
```

### Get the current time

```haskell
foo :: MonadBlockChain m => m ()
foo = do
    ...
    (firstMsOfCurrentSlot, lastMsOfCurrentSlot) <- currentTime
    ...
```

### Wait for at least some amount of time

```haskell
foo :: MonadBlockChain m => m ()
foo = do
    ...
    (firstMsOfCurrentSlot, lastMsOfCurrentSlot) <- currentTime
    targetSlot <- getEnclosingSlot $ lastMsOfCurrentSlot + 3_600_000 -- 1 hour
    awaitSlot targetSlot
    ...
```

### Submit a transaction for validation and...

* ... get the validated Cardano transaction
  ```haskell
  foo :: MonadBlockChain m => m ()
  foo = do
          ...
		  cardanoTx <-
            validateTxSkel $
			  txSkelTemplate
			    { txSkelIns = ...,
                  ... 
		        }
		  ...
  ```
* ... get the generated `TxOutRef`s
  ```haskell
  foo :: MonadBlockChain m => m ()
  foo = do
          ...
		  txOutRefs <-
            validateTxSkel' $
		  	  txSkelTemplate
			    { txSkelIns = ...,
                  ...
                }
          ...
  ```
* ... ignore any returned value
  ```haskell
  foo :: MonadBlockChain m => m ()
  foo = do
          ...
          validateTxSkel_ $
		    txSkelTemplate
		      { txSkelIns = ...,
                ...
              }
          ...
  ```

### Use wallets

* 10 wallets: `wallet 1` to `wallet 10`
* `walletAddress (wallet 3)`
* `walletPKHash (wallet 2)`

### Sign a transaction with a wallet

```haskell
txSkelTemplate
    { ...
      txSkelSigners = [wallet 1]
      ...
    }
```

### Pay (transaction output)

* `paysPK (wallet 3) (ada 6)`
* `paysScript fooTypedValidator FooTypedDatum (ada 6)`

```haskell
txSkelTemplate
    { ...
      txSkelOuts = [paysPK ..., paysScript ...]
      ...
    }
```

### Spend some UTxOs

* No redeemer: `emptyTxSkelRedeemer`
* With a given redeemer: `someTxSkelRedeemer myRedeemer`
* Attach a reference input (with a reference script): `redeemer \`withReferenceInput\` txOutRef`

```haskell
txSkelTemplate
    { ...
      txSkelIns = Map.fromList [(txOutRef1, myRedeemer1), (txOutRef2, myRedeemer2 `withReferenceInput` txOutRef)]
      ...
    }
```

* Allow automatic attachment of reference scripts:
```
txSkelTemplate
    { ...
      txSkelIns = Map.fromList [(txOutRef1, myRedeemer1), (txOutRef2, myRedeemer2)],
	  txSkelOpts = def { txOptAutoReferenceScript = True },
      ...
    }
```


### Return `TxOutRef`s from transaction outputs from...

* ... the Cardano transaction
  ```haskell
  endpointFoo :: MonadBlockChain m => m (Api.TxOutRef, Api.TxOutRef)
  endpointFoo = do
    cTx <- validateTxSkel $ txSkelTemplate { ..., ... }
    let (txOutRef1, _) : (txOutRef2, _) : _ = utxosFromCardanoTx cTx
    return (txOutRef1, txOutRef2)
  ```
* ... the returned `TxOutRef`s
  ```haskell
  endpointFoo :: MonadBlockChain m => m (Api.TxOutRef, Api.TxOutRef)
  endpointFoo = do
    txOutRef1 : txOutRef2 : _ <- validateTxSkel' $ txSkelTemplate { ..., ... }
    return (txOutRef1, txOutRef2)
  ```

### Resolve a `TxOutRef` (get the corresponding `TxOut`)

```haskell
foo :: MonadBlockChain m => Api.TxOutRef -> m ()
foo txOutRef = do
    Just txOut <- txOutByRef txOutRef
```

### Resolve the address, value, and datum of a `TxOutRef`

```haskell
foo :: MonadBlockChain m => Api.TxOutRef -> m ()
foo txOutRef = do
    Just address <- outputAddress <$> txOutByRef txOutRef
    Just value <- valueFromTxOutRef txOutRef
    Just datum <- typedDatumFromTxOutRef @typeOfDatum txOutRef
```

### Mint or burn tokens

* Mint tokens: positive amount
* Burn tokens: negative amount

* No redeemer: `(Script.Versioned fooPolicy Script.PlutusV3, emptyTxSkelRedeemer, "fooName", 3)`
* With redeemer: `(Script.Versioned barPolicy Script.PlutusV3, someTxSkelRedeemer typedRedeemer, "barName", -3)`
* With a redeemer and explicit reference script: `(Script.Versioned barPolicy Script.PlutusV3, someTxSkelRedeemer typedRedeemer \`withReferenceInput\`, "barName", 12)`
* With a redeemer and implicit reference script: `(Script.Versioned barPolicy Script.PlutusV3, someTxSkelRedeemer typedRedeemer, "fooName", -6)`, and turn on option `txOptAutoReferenceScript`

```haskell
txSkelTemplate
  { ...
    txSkelMints = txSkelMintsFromList
      [ (Script.Versioned fooPolicy Script.PlutusV3, ..., ..., ...),
        (Script.Versioned barPolicy Script.PlutusV3, ..., ..., ...)
      ]
    ...
  }
```

### Automatically provide enough Ada to output UTxOs

```haskell
txSkelTemplate
    { ...
      txOpts = def {txOptEnsureMinAda = True}
      ...
    }
```
### Have pre-existing non-Ada tokens that cannot be minted or burnt

* `distributionFromList [..., (... <> permanentValue "customToken" 1000), ...]`
* `paysPK ... (permanentValue "customToken" 7)`

### Provide a datum in a pubkey transaction output

* ``paysPK ... `withDatum` FooTypedDatum``

### Inline a datum in a transaction output

* ``paysPK ... `withInlineDatum` FooTypedDatum``
* `paysScriptInlineDatum fooTypedValidator FooTypedDatum (ada 6)`

### Provide a hashed datum, that is not resolved in the transaction, in a transaction output

* ``paysPK ... `withDatumHash` FooTypedDatum``
* `paysScriptDatumHash fooTypedValidator FooTypedDatum (ada 6)`

### Pay a script a datum whose type may not match the validator's

* ``paysScriptNoDatum fooTypedValidator (ada 6) `withDatum` FooTypedDatum``
* ``paysScriptNoDatum fooTypedValidator (ada 6) `withInlineDatum` FooTypedDatum``
* ``paysScriptNoDatum fooTypedValidator (ada 6) `withDatumHash` FooTypedDatum``

### Use reference inputs in a transaction

```haskell
txSkelTemplate
    { ...
      txSkelInsReference = Set.fromList [txOutRef1, txOutRef2, ...]
      ...
    }
```

### Include a reference script in a transaction output

* ``paysPK ... `withReferenceScript` fooTypedValidator``
* ``paysScript... ... `withReferenceScript` fooTypedValidator``

### Include a staking credential in a transaction output

* ``paysPK ... `withStakingCredential` ...``
* ``paysScript... ... `withStakingCredential` ...``

### Spend a referenced script output

```haskell
txSkelTemplate
  { ...
    txSkelIns = Map.fromList [(scriptTxOutRefToSpend, txSkelSomeRedeemerForReferencedScript txOutRefCarryingReferenceScript redeemer), ...],
    ...
  }
```

## Balancing

### Choose which wallet provides UTxOs to balance a transaction

First signer (default):

```haskell
txSkelTemplate
  { ...
    txSkelSigners = [wallet 1, wallet 2]
    ...
  }
```

Another signer:

```haskell
txSkelTemplate
  { ...
    txSkelSigners = [wallet 1, wallet 2],
    txOpts = def {txOptBalancingPolicy = BalanceWith (wallet 2)}
    ...
  }
```

### Do not automatically balance

```haskell
txSkelTemplate
  { ...
    txSkelSigners = [wallet 1, wallet 2],
    txOpts = def {txOptBalancingPolicy = DoNotBalance}
    ...
  }
```

## Provide collaterals

From first signer (default):

```
txSkelTemplate
  { ...
    txSkelSigners = [wallet 1, wallet 2]
    ...
  }
```

From another wallet:

```
txSkelTemplate
  { ...
    txSkelSigners = [wallet 1],
	txSkelCollateralUtxos = CollateralUtxosFromWallet (wallet 2)
    ...
  }
```

From a direct Utxo list:

```
txSkelTemplate
  { ...
    txSkelSigners = [wallet 1],
	txSkelCollateralUtxos = CollateralUtxosFromSet (Set.fromList [txOutRef1, txOutRef2])
    ...
  }
```

## Search through UTxOs on the ledger

### Fetch all UTxOs on the ledger

```haskell
foo :: MonadBlockChain m => m ()
foo = do
    ...
    -- searchResults :: [(Api.TxOutRef, Api.TxOut)]
    searchResults <- runUtxoSearch $ allUtxos
    ...
```

### Fetch all UTxOs at an address

```haskell
foo :: MonadBlockChain m => m () 
foo = do                  
    ...
    -- searchResults :: [(Api.TxOutRef, Api.TxOut)]
    searchResults <- runUtxoSearch $ utxosAtSearch (walletAddress (wallet 2))
    ...
```

### Search for UTxOs satisfying a predicate

```haskell
foo :: MonadBlockChain m => m ()
foo = do
    ...
    searchResults <-
      runUtxoSearch $
        allUtxos `filterWithPred` ((== ada 10) . outputValue)
    ...
```

### Search for UTxOs without datum

```haskell
foo :: MonadBlockChain m => m ()
foo = do
    ...
    searchResults <- runUtxoSearch $ allUtxos `filterWithPure` isOutputWithoutDatum
    ...
```

### Combine filters in a UTxOs search

```haskell
foo :: MonadBlockChain m => m ()
foo = do
    ...
    searchResults <-
      runUtxoSearch $
        utxosAtSearch (walletAddress (wallet 2))
          `filterWithPure` isOutputWithoutDatum
          `filterWithPred` ((== ada 10) . outputValue)
    ...
```

## Tweaks: modify traces and endpoints

### Apply a modification

```haskell
foo :: MonadBlockChain m => m ()
foo = do
    bar `withTweak` modification
```

### Add or remove inputs and outputs

```haskell
foo :: MonadBlockChain m => m ()
foo = do
    bar `withTweak` ( do
                        addOutputTweak $ paysScript bazValidator bazDatum bazValue
                        removeOutputTweak (\(Pays out) -> somePredicate out)
                        addInputTweak somePkTxOutRef txSkelEmptyRedeemer
                        removeInputTweak (\txOutRef redeemer -> somePredicate txOutRef redeemer)
                    )
```

### Modify signers

```haskell
foo :: MonadBlockChain m => m ()
foo = do
    bar `withTweak` ( do
                        addSignersTweak [alice, bob]
                        replaceFirstSigner carol
                        removeSigners [eve]
                    )
```

### Modify skeleton (inputs, outputs, options, etc.) using lenses

```haskell
foo :: MonadBlockChain m => m ()
foo = do
    bar `withTweak` ( do
                        C.overTweak
                          (txSkelOutsL % _head % txSkelOutValueL) -- Value of first output
                          (<> assetClassValue bazAssetClass 10) -- Add 10 baz tokens
                    )
```

## Proposal procedures

### Attach a Proposal Procedure to a transaction

* Using the builtin constructor for proposals.

```haskell
txSkelTemplate
  { ...
    txSkelProposals =
      [ TxSkelProposal
          { txSkelProposalAddress = walletAddress (wallet 1),
            txSkelProposalAction =
              TxGovActionTreasuryWithdrawals $
                Map.fromList
                  [ (toCredential $ wallet 1, Api.Lovelace 100),
                    (toCredential $ wallet 2, Api.Lovelace 10_000)
                  ],
            txSkelProposalWitness = (toScript myScript, myRedeemer),
            txSkelProposalAnchor = Nothing
          }
      ]
    ...
  }
```

* Using smart constructors and (optional) helpers.

```haskell 
txSkelTemplate
  { ...
    txSkelProposals =
      [ simpleTxSkelProposal
          (wallet 1)
          (TxGovActionParameterChange [FeePerByte 100, FeeFixed 1_000])
          `withWitness` (myScript, myRedeemer)
          `withAnchor` "https://www.tweag.io/"
      ]
    ...
  } 
```

### Anchor resolution policy

* Auto resolution using a given map with resolved page content as bytestrings
  (default behavior)

```haskell 
    txSkelOpts = def 
	  { txOptAnchorResolution = AnchorResolutionLocal $ Map.singleton "https://www.tweag.io/" someByteString
	  }
```

* Auto resolution using web requests (very unsafe, prevents reproducibility)

```haskell 
    txSkelOpts = def 
	  { txOptAnchorResolution = AnchorResolutionHttp
	  }
```	
