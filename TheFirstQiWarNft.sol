// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../.deps/github.com/openzeppelin/openzeppelin-contracts/contracts/utils/Strings.sol";
import "./GamifiedNft.sol";

/// @notice expose userInfo from the escrowed QI contract
interface IeQI {
    function userInfo(address user)
        external
        view
        returns (uint256 amount, uint256 endBlock);
}

/**
* @title The First QI War NFT
* @notice A game for the Qi DAO, an earlier mint order and a later burn order gives a larger payout
*/
contract TheFirstQiWarNft is GamifiedNft {

    // The reward token for the GamifiedNft
    address constant QI = 0x580A84C73811E1839F75d86d75d88cCa0c241fF4;
    // Escrowed QI contract, used for checking minting eligibility
    IeQI constant eQI = IeQI(0x880DeCADe22aD9c58A8A4202EF143c4F305100B3);

    // Minting eligibility requirements
    uint256 constant public qiRequiredToMint1 = 50 ether;
    uint256 constant public qiRequiredToMint2 = 100 ether;
    uint256 constant public qiRequiredLockedUtil = 29500000;

    // Payout ratios for payout calculation
    uint256 constant public mintOrderPayRatio = 4;
    uint256 constant public burnOrderPayRatio = 40;

    // BaseURI for tokenURI()
    string public baseURI;
    // Precision for calculations
    uint256 constant internal precision = 10**18;

    constructor()
        GamifiedNft(QI, 1646841600, 1648051200)
    {
        nftName = "The First Qi War";
        nftSymbol = "TFQW";
        baseURI = "https://api.miyazaki.ai/daos/qi/the-first-qi-war/nfts/";
        minimumContribution = 1 ether;
    }

    /**
    * @notice mint eligibility information for an address
    * @param _address to check eligibility
    * @return _minted number of NFTs this address has already minted
    * @return _eligibleCount number of NFTs this address is eligible to mint
    * @return _qiAmount amount of QI locked
    * @return _qiAmountRequired1 amount of QI required to mint 1 NFT
    * @return _qiAmountRequired2 amount of QI required to mint 2 NFTs
    * @return _lockedUntil block number address has locked QI until
    * @return _lockedUntilRequired block number QI must be locked until
    */
    function eligibility(address _address)
        public
        view
        returns (
            uint256 _minted,
            uint256 _eligibleCount,
            uint256 _qiAmount,
            uint256 _qiAmountRequired1,
            uint256 _qiAmountRequired2,
            uint256 _lockedUntil,
            uint256 _lockedUntilRequired
        )
    {
        (_qiAmount, _lockedUntil) = eQI.userInfo(_address);
        if(_lockedUntil >= qiRequiredLockedUtil) {
            if(_qiAmount >= qiRequiredToMint2) {
                _eligibleCount = 2;
            }
            else if(_qiAmount >= qiRequiredToMint1) {
                _eligibleCount = 1;
            }
        }

        return (
            mintCount[_address],
            _eligibleCount,
            _qiAmount,
            qiRequiredToMint1,
            qiRequiredToMint2,
            _lockedUntil,
            qiRequiredLockedUtil
        );
    }

    /// @inheritdoc GamifiedNft
    modifier eligibleForMint()
        override
    {
        (uint256 minted, uint256 eligibleCount,,,,,) = eligibility(msg.sender);
        require(minted < eligibleCount, "Not eligible to mint");
        _;
    }

    /// @inheritdoc GamifiedNft
    function payout(uint256 _tokenId)
        public
        view
        override
        returns (uint256 _amount)
    {
        return calculatePayout(tokensMinted, rewardAmount, _tokenId, tokensBurned + 1);
    }

    /**
    * @notice calculate the payout using mint and burn order
    * @param _nftCount total number of NFTs that will be splitting the reward
    * @param _rewardAmount total amount contributed to the reward pool
    * @param _mintOrder NFT mint order
    * @param _mintOrder NFT burn order
    * @return _amount of reward to be paid
    */
    function calculatePayout(
        uint256 _nftCount,
        uint256 _rewardAmount,
        uint256 _mintOrder,
        uint256 _burnOrder
    )
        public
        pure
        returns (uint256 _amount)
    {
        require(_mintOrder > 0 && _burnOrder > 0, 'order must be greater than 0');
        require(_mintOrder <= _nftCount && _burnOrder <= _nftCount, 'order must be less than or equal to _nftCount');

        if(_nftCount == 1) {
            return _rewardAmount;
        }

        // 1. Sum of sequence [S = n/2(a+l)] is used to create a number of mint and burn shares.
        //    The number of shares is such that there is a predetermined ratio between the number
        //    of shares that the best and worst case minters and burners will receive. For example
        //    the first minter will always receive 4 shares, and the last minter will always receive 1
        //    share, regardless of the number of participants.
        // 2. The mint and burn reward amount (half of the total reward) is divided by the total number of
        //    shares to determine a value per share.
        // 3. Determine the incremental number of shares rewarded for each mint and burn order.
        // 4. Calculate the total number of shares rewarded for the given mint and burn order.
        // 5. Give the payout for the given mint and burn order.

        uint256 mintShares = _nftCount * precision / 2 * (1 + mintOrderPayRatio);
        uint256 mintShareValue = _rewardAmount * precision / 2 / mintShares;
        uint256 mintIncrement = (mintOrderPayRatio - 1) * precision / (_nftCount - 1);
        
        // Earlier mint order gives more shares
        uint256 sharesFromMint = (1 * precision) + ((_nftCount - _mintOrder) * mintIncrement);
        uint256 mintPayout = sharesFromMint * mintShareValue / precision;

        uint256 burnShares = _nftCount * precision / 2 * (1 + burnOrderPayRatio);
        uint256 burnShareValue = _rewardAmount * precision / 2 / burnShares;
        uint256 burnIncrement = (burnOrderPayRatio - 1) * precision / (_nftCount - 1);
        
        // Later burn order gives more shares
        uint256 sharesFromBurn = (1 * precision) + ((_burnOrder - 1) * burnIncrement);
        uint256 burnPayout = sharesFromBurn * burnShareValue / precision;

        return mintPayout + burnPayout;
    }

    /**
    * @notice convenience function to get all NFT IDs owned by an address at once
    * @dev the number of elements returned may be large, should not be used by contracts
    * @param _owner address to retrieve NFT IDs
    * @return array of NFT IDs
    */
    function tokensOfOwner(address _owner)
        external
        view
        returns (uint256[] memory)
    {
        return ownerToIds[_owner];
    }

    /**
    * @notice update the base URI
    * @param _baseURI new base URI
    */
    function setBaseURI(string calldata _baseURI)
        external
        onlyOwner
    {
        baseURI = _baseURI;
    }

    /// @inheritdoc NFTokenMetadata
    function _tokenURI(
        uint256 _tokenId
    )
        internal
        override
        view
        returns (string memory)
    {
        return string(abi.encodePacked(baseURI, Strings.toString(_tokenId), ".json"));
    }

}
