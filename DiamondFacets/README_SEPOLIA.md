 Diamonds are modular smart contract systems that can be upgraded/extended after deployment, and have virtually no size limit. More technically, a diamond is a contract with external functions that are supplied by contracts called facets. Facets are separate, independent contracts that can share internal functions, libraries, and state variables.

1. A diamond is a facade smart contract that delegatecalls into its facets to execute function calls. A diamond is stateful. Data is stored in the contract storage of a diamond.
2. A facet is a stateless smart contract or Solidity library with external functions. A facet is deployed and one or more of its functions are added to one or more diamonds. A facet does not store data within its own contract storage but it can define state and read and write to the storage of one or more diamonds. The term facet comes from the diamond industry. It is a side, or flat surface of a diamond.
3. A loupe facet is a facet that provides introspection functions. In the diamond industry, a loupe is a magnifying glass that is used to look at diamonds.
4. An immutable function is an external function that cannot be replaced or removed (because it is defined directly in the diamond, or because the diamond’s logic does not allow it to be modified).
5. A mapping for the purposes of this EIP is an association between two things and does not refer to a specific implementation.


SEPOLIA FACETS: 

0x3f26F568Dc7dF625A4864a1Cd177Ff6F586d5ccd - GNSPairsStorage
0x218d777353b94a8A04F9189545a4ECeBbb6cB8E9 - GNSReferrals
0x7370fEA2A7541Ff166919479030651ABA78B5928 - GNSFeeTiers
0xd3BBe9c14A131B810661c44e21e77B006a772c1c - GNSPriceImpact
0x46d97751A3Fa99bcF5CABB07f35A1eEB72Bb0DF0 - GNSTradingStorage
0x5d333F54f6FA5c40F3F8b0f60d84C34D28fA1634 - GNSTriggerRewards
0xEe7442aCcC1C27f2C69423576d3b1D25b563E977 - GNSTradingInteractions
0xd8D177EFc926A18EE455da6F5f6A6CfCeE5F8f58 - GNSTradingCallbacks
0x170cC5a70d6F544E5456881B586eB58180998A37 - GNSBorrowingFees
0x0498aEAD9F06512C9D6b9724243DEf3D36DE3566 - GNSPriceAggregator
0xEC79dBCE04e8869A7c86a7b81Fb5254020D1e626 - GNSTradingStateCopy
