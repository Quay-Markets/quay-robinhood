// Auto-generated from the Foundry artifact: forge inspect QuaySharedLiquidityAMM abi --json
// Regenerate after contract changes.
export const quayAbi = [
  {
    "type": "constructor",
    "inputs": [
      {
        "name": "owner_",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "BPS",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint16",
        "internalType": "uint16"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "MAX_DECAY_BPS",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint32",
        "internalType": "uint32"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "Q128",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "QUOTE_UPDATE_TYPEHASH",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "acceptOwnership",
    "inputs": [],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "allBookIds",
    "inputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "batchQuoteExactInput",
    "inputs": [
      {
        "name": "bookIds",
        "type": "bytes32[]",
        "internalType": "bytes32[]"
      },
      {
        "name": "tokenIn",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "amountIn",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "results",
        "type": "tuple[]",
        "internalType": "struct QuaySharedLiquidityAMM.QuoteResult[]",
        "components": [
          {
            "name": "valid",
            "type": "bool",
            "internalType": "bool"
          },
          {
            "name": "reason",
            "type": "uint8",
            "internalType": "enum QuayTypes.QuoteReason"
          },
          {
            "name": "bookId",
            "type": "bytes32",
            "internalType": "bytes32"
          },
          {
            "name": "liquidityGroupId",
            "type": "bytes32",
            "internalType": "bytes32"
          },
          {
            "name": "tokenIn",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "tokenOut",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "amountIn",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "netAmountIn",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "feeAmount",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "amountOut",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "availableOut",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "appliedPriceX128",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "appliedDecayBps",
            "type": "uint32",
            "internalType": "uint32"
          },
          {
            "name": "quoteNonce",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "updatedAt",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "freshUntil",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "validUntil",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "inventoryNonceOut",
            "type": "uint64",
            "internalType": "uint64"
          }
        ]
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "batchUpdateQuotesWithSig",
    "inputs": [
      {
        "name": "bookIds",
        "type": "bytes32[]",
        "internalType": "bytes32[]"
      },
      {
        "name": "quotes",
        "type": "tuple[]",
        "internalType": "struct QuayTypes.QuoteState[]",
        "components": [
          {
            "name": "nonce",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "updatedAt",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "freshUntil",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "validUntil",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "decayBpsPerSecond",
            "type": "uint32",
            "internalType": "uint32"
          },
          {
            "name": "maxDecayBps",
            "type": "uint32",
            "internalType": "uint32"
          },
          {
            "name": "bidPxX128",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "askPxX128",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "maxIn0",
            "type": "uint128",
            "internalType": "uint128"
          },
          {
            "name": "maxIn1",
            "type": "uint128",
            "internalType": "uint128"
          },
          {
            "name": "sourceHash",
            "type": "bytes32",
            "internalType": "bytes32"
          }
        ]
      },
      {
        "name": "signatures",
        "type": "bytes[]",
        "internalType": "bytes[]"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "books",
    "inputs": [
      {
        "name": "bookId",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "outputs": [
      {
        "name": "token0",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "token1",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "strategyModule",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "liquidityGroupId",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "protocolFeeBps",
        "type": "uint16",
        "internalType": "uint16"
      },
      {
        "name": "status",
        "type": "uint8",
        "internalType": "enum QuaySharedLiquidityAMM.BookStatus"
      },
      {
        "name": "createdAt",
        "type": "uint64",
        "internalType": "uint64"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "createBook",
    "inputs": [
      {
        "name": "token0",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "token1",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "liquidityGroupId",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "salt",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "protocolFeeBps",
        "type": "uint16",
        "internalType": "uint16"
      },
      {
        "name": "strategyModule",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "initialUpdater",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "bookId",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "createLiquidityGroup",
    "inputs": [
      {
        "name": "liquidityGroupId",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "groupOwner",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "deposit",
    "inputs": [
      {
        "name": "liquidityGroupId",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "token",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "amount",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "eip712Domain",
    "inputs": [],
    "outputs": [
      {
        "name": "fields",
        "type": "bytes1",
        "internalType": "bytes1"
      },
      {
        "name": "name",
        "type": "string",
        "internalType": "string"
      },
      {
        "name": "version",
        "type": "string",
        "internalType": "string"
      },
      {
        "name": "chainId",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "verifyingContract",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "salt",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "extensions",
        "type": "uint256[]",
        "internalType": "uint256[]"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "getAllBookIds",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "bytes32[]",
        "internalType": "bytes32[]"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "getAmountOut",
    "inputs": [
      {
        "name": "tokenIn",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "tokenOut",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "amountIn",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "amountOut",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "bookId",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "getBook",
    "inputs": [
      {
        "name": "bookId",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "tuple",
        "internalType": "struct QuaySharedLiquidityAMM.Book",
        "components": [
          {
            "name": "token0",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "token1",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "strategyModule",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "liquidityGroupId",
            "type": "bytes32",
            "internalType": "bytes32"
          },
          {
            "name": "protocolFeeBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "status",
            "type": "uint8",
            "internalType": "enum QuaySharedLiquidityAMM.BookStatus"
          },
          {
            "name": "createdAt",
            "type": "uint64",
            "internalType": "uint64"
          }
        ]
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "getBookState",
    "inputs": [
      {
        "name": "bookId",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "outputs": [
      {
        "name": "v",
        "type": "tuple",
        "internalType": "struct QuaySharedLiquidityAMM.BookStateView",
        "components": [
          {
            "name": "book",
            "type": "tuple",
            "internalType": "struct QuaySharedLiquidityAMM.Book",
            "components": [
              {
                "name": "token0",
                "type": "address",
                "internalType": "address"
              },
              {
                "name": "token1",
                "type": "address",
                "internalType": "address"
              },
              {
                "name": "strategyModule",
                "type": "address",
                "internalType": "address"
              },
              {
                "name": "liquidityGroupId",
                "type": "bytes32",
                "internalType": "bytes32"
              },
              {
                "name": "protocolFeeBps",
                "type": "uint16",
                "internalType": "uint16"
              },
              {
                "name": "status",
                "type": "uint8",
                "internalType": "enum QuaySharedLiquidityAMM.BookStatus"
              },
              {
                "name": "createdAt",
                "type": "uint64",
                "internalType": "uint64"
              }
            ]
          },
          {
            "name": "quote",
            "type": "tuple",
            "internalType": "struct QuayTypes.QuoteState",
            "components": [
              {
                "name": "nonce",
                "type": "uint64",
                "internalType": "uint64"
              },
              {
                "name": "updatedAt",
                "type": "uint64",
                "internalType": "uint64"
              },
              {
                "name": "freshUntil",
                "type": "uint64",
                "internalType": "uint64"
              },
              {
                "name": "validUntil",
                "type": "uint64",
                "internalType": "uint64"
              },
              {
                "name": "decayBpsPerSecond",
                "type": "uint32",
                "internalType": "uint32"
              },
              {
                "name": "maxDecayBps",
                "type": "uint32",
                "internalType": "uint32"
              },
              {
                "name": "bidPxX128",
                "type": "uint256",
                "internalType": "uint256"
              },
              {
                "name": "askPxX128",
                "type": "uint256",
                "internalType": "uint256"
              },
              {
                "name": "maxIn0",
                "type": "uint128",
                "internalType": "uint128"
              },
              {
                "name": "maxIn1",
                "type": "uint128",
                "internalType": "uint128"
              },
              {
                "name": "sourceHash",
                "type": "bytes32",
                "internalType": "bytes32"
              }
            ]
          },
          {
            "name": "oracle",
            "type": "tuple",
            "internalType": "struct QuaySharedLiquidityAMM.OracleConfig",
            "components": [
              {
                "name": "feed",
                "type": "address",
                "internalType": "address"
              },
              {
                "name": "maxAge",
                "type": "uint32",
                "internalType": "uint32"
              },
              {
                "name": "maxDeviationBps",
                "type": "uint16",
                "internalType": "uint16"
              },
              {
                "name": "priceScale",
                "type": "uint256",
                "internalType": "uint256"
              }
            ]
          },
          {
            "name": "strategyStatus",
            "type": "uint8",
            "internalType": "enum QuaySharedLiquidityAMM.StrategyStatus"
          },
          {
            "name": "groupPaused",
            "type": "bool",
            "internalType": "bool"
          },
          {
            "name": "protocolPaused",
            "type": "bool",
            "internalType": "bool"
          },
          {
            "name": "inventory0",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "inventory1",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "inventoryNonce0",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "inventoryNonce1",
            "type": "uint64",
            "internalType": "uint64"
          }
        ]
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "getBookStates",
    "inputs": [
      {
        "name": "bookIds",
        "type": "bytes32[]",
        "internalType": "bytes32[]"
      }
    ],
    "outputs": [
      {
        "name": "views",
        "type": "tuple[]",
        "internalType": "struct QuaySharedLiquidityAMM.BookStateView[]",
        "components": [
          {
            "name": "book",
            "type": "tuple",
            "internalType": "struct QuaySharedLiquidityAMM.Book",
            "components": [
              {
                "name": "token0",
                "type": "address",
                "internalType": "address"
              },
              {
                "name": "token1",
                "type": "address",
                "internalType": "address"
              },
              {
                "name": "strategyModule",
                "type": "address",
                "internalType": "address"
              },
              {
                "name": "liquidityGroupId",
                "type": "bytes32",
                "internalType": "bytes32"
              },
              {
                "name": "protocolFeeBps",
                "type": "uint16",
                "internalType": "uint16"
              },
              {
                "name": "status",
                "type": "uint8",
                "internalType": "enum QuaySharedLiquidityAMM.BookStatus"
              },
              {
                "name": "createdAt",
                "type": "uint64",
                "internalType": "uint64"
              }
            ]
          },
          {
            "name": "quote",
            "type": "tuple",
            "internalType": "struct QuayTypes.QuoteState",
            "components": [
              {
                "name": "nonce",
                "type": "uint64",
                "internalType": "uint64"
              },
              {
                "name": "updatedAt",
                "type": "uint64",
                "internalType": "uint64"
              },
              {
                "name": "freshUntil",
                "type": "uint64",
                "internalType": "uint64"
              },
              {
                "name": "validUntil",
                "type": "uint64",
                "internalType": "uint64"
              },
              {
                "name": "decayBpsPerSecond",
                "type": "uint32",
                "internalType": "uint32"
              },
              {
                "name": "maxDecayBps",
                "type": "uint32",
                "internalType": "uint32"
              },
              {
                "name": "bidPxX128",
                "type": "uint256",
                "internalType": "uint256"
              },
              {
                "name": "askPxX128",
                "type": "uint256",
                "internalType": "uint256"
              },
              {
                "name": "maxIn0",
                "type": "uint128",
                "internalType": "uint128"
              },
              {
                "name": "maxIn1",
                "type": "uint128",
                "internalType": "uint128"
              },
              {
                "name": "sourceHash",
                "type": "bytes32",
                "internalType": "bytes32"
              }
            ]
          },
          {
            "name": "oracle",
            "type": "tuple",
            "internalType": "struct QuaySharedLiquidityAMM.OracleConfig",
            "components": [
              {
                "name": "feed",
                "type": "address",
                "internalType": "address"
              },
              {
                "name": "maxAge",
                "type": "uint32",
                "internalType": "uint32"
              },
              {
                "name": "maxDeviationBps",
                "type": "uint16",
                "internalType": "uint16"
              },
              {
                "name": "priceScale",
                "type": "uint256",
                "internalType": "uint256"
              }
            ]
          },
          {
            "name": "strategyStatus",
            "type": "uint8",
            "internalType": "enum QuaySharedLiquidityAMM.StrategyStatus"
          },
          {
            "name": "groupPaused",
            "type": "bool",
            "internalType": "bool"
          },
          {
            "name": "protocolPaused",
            "type": "bool",
            "internalType": "bool"
          },
          {
            "name": "inventory0",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "inventory1",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "inventoryNonce0",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "inventoryNonce1",
            "type": "uint64",
            "internalType": "uint64"
          }
        ]
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "getBooksForPair",
    "inputs": [
      {
        "name": "tokenA",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "tokenB",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bytes32[]",
        "internalType": "bytes32[]"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "getQuoteState",
    "inputs": [
      {
        "name": "bookId",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "tuple",
        "internalType": "struct QuayTypes.QuoteState",
        "components": [
          {
            "name": "nonce",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "updatedAt",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "freshUntil",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "validUntil",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "decayBpsPerSecond",
            "type": "uint32",
            "internalType": "uint32"
          },
          {
            "name": "maxDecayBps",
            "type": "uint32",
            "internalType": "uint32"
          },
          {
            "name": "bidPxX128",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "askPxX128",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "maxIn0",
            "type": "uint128",
            "internalType": "uint128"
          },
          {
            "name": "maxIn1",
            "type": "uint128",
            "internalType": "uint128"
          },
          {
            "name": "sourceHash",
            "type": "bytes32",
            "internalType": "bytes32"
          }
        ]
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "getUpdaters",
    "inputs": [
      {
        "name": "bookId",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "address[]",
        "internalType": "address[]"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "hashQuoteUpdate",
    "inputs": [
      {
        "name": "bookId",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "q",
        "type": "tuple",
        "internalType": "struct QuayTypes.QuoteState",
        "components": [
          {
            "name": "nonce",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "updatedAt",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "freshUntil",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "validUntil",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "decayBpsPerSecond",
            "type": "uint32",
            "internalType": "uint32"
          },
          {
            "name": "maxDecayBps",
            "type": "uint32",
            "internalType": "uint32"
          },
          {
            "name": "bidPxX128",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "askPxX128",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "maxIn0",
            "type": "uint128",
            "internalType": "uint128"
          },
          {
            "name": "maxIn1",
            "type": "uint128",
            "internalType": "uint128"
          },
          {
            "name": "sourceHash",
            "type": "bytes32",
            "internalType": "bytes32"
          }
        ]
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "inventory",
    "inputs": [
      {
        "name": "liquidityGroupId",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "token",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "inventoryNonce",
    "inputs": [
      {
        "name": "liquidityGroupId",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "token",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint64",
        "internalType": "uint64"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "isStrategyAuthor",
    "inputs": [
      {
        "name": "author",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "isUpdater",
    "inputs": [
      {
        "name": "bookId",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "updater",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "liquidityGroups",
    "inputs": [
      {
        "name": "liquidityGroupId",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "outputs": [
      {
        "name": "owner",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "exists",
        "type": "bool",
        "internalType": "bool"
      },
      {
        "name": "paused",
        "type": "bool",
        "internalType": "bool"
      },
      {
        "name": "createdAt",
        "type": "uint64",
        "internalType": "uint64"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "oracleConfigs",
    "inputs": [
      {
        "name": "bookId",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "outputs": [
      {
        "name": "feed",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "maxAge",
        "type": "uint32",
        "internalType": "uint32"
      },
      {
        "name": "maxDeviationBps",
        "type": "uint16",
        "internalType": "uint16"
      },
      {
        "name": "priceScale",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "owner",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "pause",
    "inputs": [],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "paused",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "pendingOwner",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "protocolFees",
    "inputs": [
      {
        "name": "liquidityGroupId",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "token",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "quoteBestExactInput",
    "inputs": [
      {
        "name": "tokenIn",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "tokenOut",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "amountIn",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "best",
        "type": "tuple",
        "internalType": "struct QuaySharedLiquidityAMM.QuoteResult",
        "components": [
          {
            "name": "valid",
            "type": "bool",
            "internalType": "bool"
          },
          {
            "name": "reason",
            "type": "uint8",
            "internalType": "enum QuayTypes.QuoteReason"
          },
          {
            "name": "bookId",
            "type": "bytes32",
            "internalType": "bytes32"
          },
          {
            "name": "liquidityGroupId",
            "type": "bytes32",
            "internalType": "bytes32"
          },
          {
            "name": "tokenIn",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "tokenOut",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "amountIn",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "netAmountIn",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "feeAmount",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "amountOut",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "availableOut",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "appliedPriceX128",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "appliedDecayBps",
            "type": "uint32",
            "internalType": "uint32"
          },
          {
            "name": "quoteNonce",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "updatedAt",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "freshUntil",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "validUntil",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "inventoryNonceOut",
            "type": "uint64",
            "internalType": "uint64"
          }
        ]
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "quoteExactInput",
    "inputs": [
      {
        "name": "bookId",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "tokenIn",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "amountIn",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "tuple",
        "internalType": "struct QuaySharedLiquidityAMM.QuoteResult",
        "components": [
          {
            "name": "valid",
            "type": "bool",
            "internalType": "bool"
          },
          {
            "name": "reason",
            "type": "uint8",
            "internalType": "enum QuayTypes.QuoteReason"
          },
          {
            "name": "bookId",
            "type": "bytes32",
            "internalType": "bytes32"
          },
          {
            "name": "liquidityGroupId",
            "type": "bytes32",
            "internalType": "bytes32"
          },
          {
            "name": "tokenIn",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "tokenOut",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "amountIn",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "netAmountIn",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "feeAmount",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "amountOut",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "availableOut",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "appliedPriceX128",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "appliedDecayBps",
            "type": "uint32",
            "internalType": "uint32"
          },
          {
            "name": "quoteNonce",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "updatedAt",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "freshUntil",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "validUntil",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "inventoryNonceOut",
            "type": "uint64",
            "internalType": "uint64"
          }
        ]
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "quotePriceOnly",
    "inputs": [
      {
        "name": "bookId",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "tokenIn",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "amountIn",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "r",
        "type": "tuple",
        "internalType": "struct QuaySharedLiquidityAMM.QuoteResult",
        "components": [
          {
            "name": "valid",
            "type": "bool",
            "internalType": "bool"
          },
          {
            "name": "reason",
            "type": "uint8",
            "internalType": "enum QuayTypes.QuoteReason"
          },
          {
            "name": "bookId",
            "type": "bytes32",
            "internalType": "bytes32"
          },
          {
            "name": "liquidityGroupId",
            "type": "bytes32",
            "internalType": "bytes32"
          },
          {
            "name": "tokenIn",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "tokenOut",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "amountIn",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "netAmountIn",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "feeAmount",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "amountOut",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "availableOut",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "appliedPriceX128",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "appliedDecayBps",
            "type": "uint32",
            "internalType": "uint32"
          },
          {
            "name": "quoteNonce",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "updatedAt",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "freshUntil",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "validUntil",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "inventoryNonceOut",
            "type": "uint64",
            "internalType": "uint64"
          }
        ]
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "quoteStates",
    "inputs": [
      {
        "name": "bookId",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "outputs": [
      {
        "name": "nonce",
        "type": "uint64",
        "internalType": "uint64"
      },
      {
        "name": "updatedAt",
        "type": "uint64",
        "internalType": "uint64"
      },
      {
        "name": "freshUntil",
        "type": "uint64",
        "internalType": "uint64"
      },
      {
        "name": "validUntil",
        "type": "uint64",
        "internalType": "uint64"
      },
      {
        "name": "decayBpsPerSecond",
        "type": "uint32",
        "internalType": "uint32"
      },
      {
        "name": "maxDecayBps",
        "type": "uint32",
        "internalType": "uint32"
      },
      {
        "name": "bidPxX128",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "askPxX128",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "maxIn0",
        "type": "uint128",
        "internalType": "uint128"
      },
      {
        "name": "maxIn1",
        "type": "uint128",
        "internalType": "uint128"
      },
      {
        "name": "sourceHash",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "registerStrategy",
    "inputs": [
      {
        "name": "module",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "renounceOwnership",
    "inputs": [],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "retireStrategy",
    "inputs": [
      {
        "name": "module",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "setBookOracle",
    "inputs": [
      {
        "name": "bookId",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "feed",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "maxAge",
        "type": "uint32",
        "internalType": "uint32"
      },
      {
        "name": "maxDeviationBps",
        "type": "uint16",
        "internalType": "uint16"
      },
      {
        "name": "priceScale",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "setBookStatus",
    "inputs": [
      {
        "name": "bookId",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "newStatus",
        "type": "uint8",
        "internalType": "enum QuaySharedLiquidityAMM.BookStatus"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "setLiquidityGroupPaused",
    "inputs": [
      {
        "name": "liquidityGroupId",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "paused_",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "setStrategyApproval",
    "inputs": [
      {
        "name": "module",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "approved",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "setStrategyAuthor",
    "inputs": [
      {
        "name": "author",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "allowed",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "setUpdater",
    "inputs": [
      {
        "name": "bookId",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "updater",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "active",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "strategies",
    "inputs": [
      {
        "name": "module",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "author",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "registeredAt",
        "type": "uint64",
        "internalType": "uint64"
      },
      {
        "name": "status",
        "type": "uint8",
        "internalType": "enum QuaySharedLiquidityAMM.StrategyStatus"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "swapExactInputSingle",
    "inputs": [
      {
        "name": "p",
        "type": "tuple",
        "internalType": "struct QuaySharedLiquidityAMM.SwapExactInputSingleParams",
        "components": [
          {
            "name": "bookId",
            "type": "bytes32",
            "internalType": "bytes32"
          },
          {
            "name": "tokenIn",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "tokenOut",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "amountIn",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "minAmountOut",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "recipient",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "deadline",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "expectedQuoteNonce",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "expectedInventoryNonceOut",
            "type": "uint64",
            "internalType": "uint64"
          }
        ]
      }
    ],
    "outputs": [
      {
        "name": "amountOut",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "transferOwnership",
    "inputs": [
      {
        "name": "newOwner",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "unpause",
    "inputs": [],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "updateQuote",
    "inputs": [
      {
        "name": "bookId",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "q",
        "type": "tuple",
        "internalType": "struct QuayTypes.QuoteState",
        "components": [
          {
            "name": "nonce",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "updatedAt",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "freshUntil",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "validUntil",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "decayBpsPerSecond",
            "type": "uint32",
            "internalType": "uint32"
          },
          {
            "name": "maxDecayBps",
            "type": "uint32",
            "internalType": "uint32"
          },
          {
            "name": "bidPxX128",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "askPxX128",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "maxIn0",
            "type": "uint128",
            "internalType": "uint128"
          },
          {
            "name": "maxIn1",
            "type": "uint128",
            "internalType": "uint128"
          },
          {
            "name": "sourceHash",
            "type": "bytes32",
            "internalType": "bytes32"
          }
        ]
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "updateQuoteWithSig",
    "inputs": [
      {
        "name": "bookId",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "q",
        "type": "tuple",
        "internalType": "struct QuayTypes.QuoteState",
        "components": [
          {
            "name": "nonce",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "updatedAt",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "freshUntil",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "validUntil",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "decayBpsPerSecond",
            "type": "uint32",
            "internalType": "uint32"
          },
          {
            "name": "maxDecayBps",
            "type": "uint32",
            "internalType": "uint32"
          },
          {
            "name": "bidPxX128",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "askPxX128",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "maxIn0",
            "type": "uint128",
            "internalType": "uint128"
          },
          {
            "name": "maxIn1",
            "type": "uint128",
            "internalType": "uint128"
          },
          {
            "name": "sourceHash",
            "type": "bytes32",
            "internalType": "bytes32"
          }
        ]
      },
      {
        "name": "signature",
        "type": "bytes",
        "internalType": "bytes"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "withdraw",
    "inputs": [
      {
        "name": "liquidityGroupId",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "token",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "amount",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "to",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "withdrawProtocolFees",
    "inputs": [
      {
        "name": "liquidityGroupId",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "token",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "amount",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "to",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "event",
    "name": "BookCreated",
    "inputs": [
      {
        "name": "bookId",
        "type": "bytes32",
        "indexed": true,
        "internalType": "bytes32"
      },
      {
        "name": "token0",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "token1",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "liquidityGroupId",
        "type": "bytes32",
        "indexed": false,
        "internalType": "bytes32"
      },
      {
        "name": "protocolFeeBps",
        "type": "uint16",
        "indexed": false,
        "internalType": "uint16"
      },
      {
        "name": "strategyModule",
        "type": "address",
        "indexed": false,
        "internalType": "address"
      },
      {
        "name": "status",
        "type": "uint8",
        "indexed": false,
        "internalType": "enum QuaySharedLiquidityAMM.BookStatus"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "BookOracleSet",
    "inputs": [
      {
        "name": "bookId",
        "type": "bytes32",
        "indexed": true,
        "internalType": "bytes32"
      },
      {
        "name": "feed",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "maxAge",
        "type": "uint32",
        "indexed": false,
        "internalType": "uint32"
      },
      {
        "name": "maxDeviationBps",
        "type": "uint16",
        "indexed": false,
        "internalType": "uint16"
      },
      {
        "name": "priceScale",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "BookStatusChanged",
    "inputs": [
      {
        "name": "bookId",
        "type": "bytes32",
        "indexed": true,
        "internalType": "bytes32"
      },
      {
        "name": "oldStatus",
        "type": "uint8",
        "indexed": false,
        "internalType": "enum QuaySharedLiquidityAMM.BookStatus"
      },
      {
        "name": "newStatus",
        "type": "uint8",
        "indexed": false,
        "internalType": "enum QuaySharedLiquidityAMM.BookStatus"
      },
      {
        "name": "actor",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "EIP712DomainChanged",
    "inputs": [],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "LiquidityDeposited",
    "inputs": [
      {
        "name": "liquidityGroupId",
        "type": "bytes32",
        "indexed": true,
        "internalType": "bytes32"
      },
      {
        "name": "token",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "from",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "amount",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "inventoryAfter",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "inventoryNonceAfter",
        "type": "uint64",
        "indexed": false,
        "internalType": "uint64"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "LiquidityGroupCreated",
    "inputs": [
      {
        "name": "liquidityGroupId",
        "type": "bytes32",
        "indexed": true,
        "internalType": "bytes32"
      },
      {
        "name": "groupOwner",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "LiquidityGroupPaused",
    "inputs": [
      {
        "name": "liquidityGroupId",
        "type": "bytes32",
        "indexed": true,
        "internalType": "bytes32"
      },
      {
        "name": "paused",
        "type": "bool",
        "indexed": false,
        "internalType": "bool"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "LiquidityWithdrawn",
    "inputs": [
      {
        "name": "liquidityGroupId",
        "type": "bytes32",
        "indexed": true,
        "internalType": "bytes32"
      },
      {
        "name": "token",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "to",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "amount",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "inventoryAfter",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "inventoryNonceAfter",
        "type": "uint64",
        "indexed": false,
        "internalType": "uint64"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "OwnershipTransferStarted",
    "inputs": [
      {
        "name": "previousOwner",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "newOwner",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "OwnershipTransferred",
    "inputs": [
      {
        "name": "previousOwner",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "newOwner",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "Paused",
    "inputs": [
      {
        "name": "account",
        "type": "address",
        "indexed": false,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "ProtocolFeesWithdrawn",
    "inputs": [
      {
        "name": "liquidityGroupId",
        "type": "bytes32",
        "indexed": true,
        "internalType": "bytes32"
      },
      {
        "name": "token",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "to",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "amount",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "QuoteUpdated",
    "inputs": [
      {
        "name": "bookId",
        "type": "bytes32",
        "indexed": true,
        "internalType": "bytes32"
      },
      {
        "name": "nonce",
        "type": "uint64",
        "indexed": false,
        "internalType": "uint64"
      },
      {
        "name": "updatedAt",
        "type": "uint64",
        "indexed": false,
        "internalType": "uint64"
      },
      {
        "name": "freshUntil",
        "type": "uint64",
        "indexed": false,
        "internalType": "uint64"
      },
      {
        "name": "validUntil",
        "type": "uint64",
        "indexed": false,
        "internalType": "uint64"
      },
      {
        "name": "bidPxX128",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "askPxX128",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "maxIn0",
        "type": "uint128",
        "indexed": false,
        "internalType": "uint128"
      },
      {
        "name": "maxIn1",
        "type": "uint128",
        "indexed": false,
        "internalType": "uint128"
      },
      {
        "name": "sourceHash",
        "type": "bytes32",
        "indexed": false,
        "internalType": "bytes32"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "StrategyAuthorSet",
    "inputs": [
      {
        "name": "author",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "allowed",
        "type": "bool",
        "indexed": false,
        "internalType": "bool"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "StrategyRegistered",
    "inputs": [
      {
        "name": "module",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "author",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "StrategyStatusChanged",
    "inputs": [
      {
        "name": "module",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "oldStatus",
        "type": "uint8",
        "indexed": false,
        "internalType": "enum QuaySharedLiquidityAMM.StrategyStatus"
      },
      {
        "name": "newStatus",
        "type": "uint8",
        "indexed": false,
        "internalType": "enum QuaySharedLiquidityAMM.StrategyStatus"
      },
      {
        "name": "actor",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "Swap",
    "inputs": [
      {
        "name": "bookId",
        "type": "bytes32",
        "indexed": true,
        "internalType": "bytes32"
      },
      {
        "name": "liquidityGroupId",
        "type": "bytes32",
        "indexed": true,
        "internalType": "bytes32"
      },
      {
        "name": "sender",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "recipient",
        "type": "address",
        "indexed": false,
        "internalType": "address"
      },
      {
        "name": "tokenIn",
        "type": "address",
        "indexed": false,
        "internalType": "address"
      },
      {
        "name": "tokenOut",
        "type": "address",
        "indexed": false,
        "internalType": "address"
      },
      {
        "name": "amountIn",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "feeAmount",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "amountOut",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "quoteNonce",
        "type": "uint64",
        "indexed": false,
        "internalType": "uint64"
      },
      {
        "name": "inventoryNonceOutAfter",
        "type": "uint64",
        "indexed": false,
        "internalType": "uint64"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "Unpaused",
    "inputs": [
      {
        "name": "account",
        "type": "address",
        "indexed": false,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "UpdaterSet",
    "inputs": [
      {
        "name": "bookId",
        "type": "bytes32",
        "indexed": true,
        "internalType": "bytes32"
      },
      {
        "name": "updater",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "active",
        "type": "bool",
        "indexed": false,
        "internalType": "bool"
      }
    ],
    "anonymous": false
  },
  {
    "type": "error",
    "name": "ArrayLengthMismatch",
    "inputs": []
  },
  {
    "type": "error",
    "name": "BadFee",
    "inputs": []
  },
  {
    "type": "error",
    "name": "BadOracleConfig",
    "inputs": []
  },
  {
    "type": "error",
    "name": "BadQuote",
    "inputs": []
  },
  {
    "type": "error",
    "name": "BookClosed",
    "inputs": []
  },
  {
    "type": "error",
    "name": "DeadlineExpired",
    "inputs": []
  },
  {
    "type": "error",
    "name": "ECDSAInvalidSignature",
    "inputs": []
  },
  {
    "type": "error",
    "name": "ECDSAInvalidSignatureLength",
    "inputs": [
      {
        "name": "length",
        "type": "uint256",
        "internalType": "uint256"
      }
    ]
  },
  {
    "type": "error",
    "name": "ECDSAInvalidSignatureS",
    "inputs": [
      {
        "name": "s",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ]
  },
  {
    "type": "error",
    "name": "EnforcedPause",
    "inputs": []
  },
  {
    "type": "error",
    "name": "ExpectedPause",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InsufficientInventory",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidAddress",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidBook",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidGroup",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidShortString",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidStrategy",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InventoryNonceMismatch",
    "inputs": []
  },
  {
    "type": "error",
    "name": "NonStandardToken",
    "inputs": []
  },
  {
    "type": "error",
    "name": "NotGroupOwner",
    "inputs": []
  },
  {
    "type": "error",
    "name": "NotStrategyAuthor",
    "inputs": []
  },
  {
    "type": "error",
    "name": "NotUpdater",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OwnableInvalidOwner",
    "inputs": [
      {
        "name": "owner",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "OwnableUnauthorizedAccount",
    "inputs": [
      {
        "name": "account",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "QuoteInvalid",
    "inputs": [
      {
        "name": "reason",
        "type": "uint8",
        "internalType": "enum QuayTypes.QuoteReason"
      }
    ]
  },
  {
    "type": "error",
    "name": "QuoteNonceMismatch",
    "inputs": []
  },
  {
    "type": "error",
    "name": "ReentrancyGuardReentrantCall",
    "inputs": []
  },
  {
    "type": "error",
    "name": "SafeERC20FailedOperation",
    "inputs": [
      {
        "name": "token",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "Slippage",
    "inputs": []
  },
  {
    "type": "error",
    "name": "StaleQuoteNonce",
    "inputs": []
  },
  {
    "type": "error",
    "name": "StrategyAlreadyRegistered",
    "inputs": []
  },
  {
    "type": "error",
    "name": "StrategyNotApprovedError",
    "inputs": []
  },
  {
    "type": "error",
    "name": "StrategyNotRegistered",
    "inputs": []
  },
  {
    "type": "error",
    "name": "StrategyRetiredError",
    "inputs": []
  },
  {
    "type": "error",
    "name": "StringTooLong",
    "inputs": [
      {
        "name": "str",
        "type": "string",
        "internalType": "string"
      }
    ]
  },
  {
    "type": "error",
    "name": "WrongTokenOut",
    "inputs": []
  }
] as const;
