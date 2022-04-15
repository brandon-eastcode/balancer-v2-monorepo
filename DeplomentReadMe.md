# Deployment

This is a fork of the balancer system https://github.com/balancer-labs/balancer-v2-monorepo. Balancer has a number of different types of pools including weighted, stable, and linear pools.

For deployment of existing contract, we made use of Remix https://remix.ethereum.org/#optimize=false&runs=200&evmVersion=null&version=soljson-v0.8.7+commit.e28d00a7.js, which is contract deployment of smart contracts. Remix can only bring in a limited amount of files and it cuts out the balance’s node_module folder, so change the import statements to import the local contract versions in its own pkg folder.

To connect remix to a localhost using this command in your local directory:

```bash
$ remixd -s ./
```

## Deploying

The following are the smart contracts for the balancer, listed in the order they should be deployed, along with the params for each of their constructors. 

### Authorizer

This will control all authorized users for the vault and factories

Compile version 0.7.6
constructor (address Admin)

### Vault

This contract will hold all the tokens staked in pools.

Compile version 0.7.6
constructor (address Authorizer, address WETH, uint256 PauseWindowDuration, uint256 BufferPeriodDuration)
\*\* note: Make sure to Enable optimization (It's a checkbox in the compiler options)

### StablePoolFactory

These are all factories to make staking pools

Compile version 0.7.6
constructor (address Vault)
\*\* note: Make sure to Enable optimization

### StablePhantomPoolFactory

Compile version 0.7.1
constructor (address Vault)
\*\* note: Make sure to Enable optimization

### WeightedPoolFactory

Compile version 0.7.1
constructor (address Vault)
\*\* note: Make sure to Enable optimization
\*\* note: This may be needed to be deployed to sync with the subgraphs (does not need to be verified)

### WeightedPool2TokensFactory

Compile version 0.7.1
constructor (address Vault)
\*\* note: Make sure to Enable optimization
\*\* note: This may be needed to be deployed to sync with the subgraphs (does not need to be verified)

## Verification

### Authorizer

Authorizer will flatten with remix flattener
\*\* note: the remix flattener is a extension that can be added to remix

### Vault

Vault is verified by multi files (46 files)
\*\* note: to verify with multi files,the paths must be taken off the imports

1. vaults.sol
2. Address.sol
3. AssetHelper.sol
4. AssetManagers.sol
5. AssetTransfersHandler.sol
6. Authentication.sol
7. BalanceAllocation.sol
8. BalancerErrors.sol
9. EIP712.sol
10. EnumerableMap.sol
11. EnumerableSet.sol
12. Fees.sol
13. FixedPoint.sol
14. FlashLoans.sol
15. GeneralPoolsBalance.sol
16. IAsset.sol
17. IAuthentication.sol
18. IAuthorizer.sol
19. IBasePool.sol
20. IERC20.sol
21. IFlashLoanRecipient.sol
22. IGeneralPool.sol
23. IMinimalSwapInfoPool.sol
24. InputHelpers.sol
25. IPoolSwapStructs.sol
26. IProtocolFeesCollector.sol
27. ISignaturesValidator.sol
28. ITemporarilyPausable.sol
29. IVault.sol
30. IWETH.sol
31. LogExpMath.sol
32. Math.sol
33. MinimalSwapInfoPoolsBalance.sol
34. PoolBalances.sol
35. PoolRegistry.sol
36. PoolTokens.sol
37. ProtocolFeesCollector.sol
38. ReentrancyGuard.sol
39. SafeCast.sol
40. SafeERC20.sol
41. SignaturesValidator.sol
42. Swaps.sol
43. TemporarilyPausable.sol
44. TwoTokenPoolsBalance.sol
45. UserBalance.sol
46. VaultAuthorization.sol

### StablePoolFactory

StablePoolFactory is verified by multi files (41 files)
\*\* note: to verify with multi files,the paths must be taken off the imports

1. WordCodec.sol
2. StablePoolFactory.sol
3. BalancerPoolToken.sol
4. IAssetManager.sol
5. BaseGeneralPool.sol
6. Authentication.sol
7. BasePoolAuthorization.sol
8. BalancerErrors.sol
9. EIP712.sol
10. BasePoolAuthorization.sol
11. BasePoolFactory.sol
12. ERC20.sol
13. FixedPoint.sol
14. ERC20Permit.sol
15. FactoryWidePauseWindow.sol
16. IAsset.sol
17. IAuthentication.sol
18. IAuthorizer.sol
19. IBasePool.sol
20. IERC20.sol
21. IFlashLoanRecipient.sol
22. IGeneralPool.sol
23. IMinimalSwapInfoPool.sol
24. InputHelpers.sol
25. IPoolSwapStructs.sol
26. IProtocolFeesCollector.sol
27. ISignaturesValidator.sol
28. ITemporarilyPausable.sol
29. IVault.sol
30. IWETH.sol
31. LogExpMath.sol
32. Math.sol
33. IERC20Permit.sol
34. IRateProvider.sol
35. LegacyBaseMinimalSwapInfoPool.sol
36. LegacyBasePool.sol
37. SafeMath.sol
38. StableMath.sol
39. StablePool.sol
40. StablePoolUserData.sol
41. SignaturesValidator.sol

### StablePhantomPoolFactory

StablePhantomPoolfactory was verified with a flattened file containing all the contract code. Flatened contracts can normally be used for quick verifications, but typical flatenning tools like remix didn't work with these contracts. Instead, it was flattened manually.
\*\* note: This contract had to deploy this a few time before it was able to get this verified
\*\* note: The files below are the order they need to be in if flattened manueally but multi file might work as well

1. BalancerErrors.sol
2. IERC20.sol
3. IAuthorizer.sol
4. ITemporarilyPausable.sol
5. IPoolSwapStructs.sol
6. IBasePool.sol
7. WordCodec.sol
8. TemporarilyPausable.sol
9. SafeMath.sol
10. ERC20.sol
11. IAssetManager.sol
12. IERC20Permit.sol
13. EIP712.sol
14. ERC20Permit.sol
15. BalancerPoolToken.sol
16. IAuthentication.sol
17. Authentication.sol
18. BasePoolAuthorization.sol
19. LegacyBasePool.sol
20. IAsset.sol
21. IRateProvider.sol
22. LogExpMath.sol
23. FixedPoint.sol
24. Math.sol
25. ISignaturesValidator.sol
26. IWETH.sol
27. IFlashLoanRecipient.sol
28. IProtocolFeesCollector.sol
29. IVault.sol
30. BasePoolFactory.sol
31. CodeDeployer.sol
32. BaseSplitCodeFactory.sol
33. BasePoolSplitCodeFactory.sol
34. FactoryWidePauseWindow.sol
35. InputHelpers.sol
36. IGeneralPool.sol
37. BaseGeneralPool.sol
38. IMinimalSwapInfoPool.sol
39. LegacyBaseMinimalSwapInfoPool.sol
40. StableMath.sol
41. StablePoolUserData.sol
42. StablePool.sol
43. PriceRateCache.sol
44. ERC20Helpers.sol
45. StablePhantomPoolUserData.sol
46. StablePhantomPool.sol
47. StablePhantomPoolFactory.sol
