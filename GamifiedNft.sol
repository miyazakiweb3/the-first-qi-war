// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../.deps/github.com/openzeppelin/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "../.deps/github.com/nibbstack/erc721/src/contracts/tokens/nf-token-enumerable.sol";
import "../.deps/github.com/nibbstack/erc721/src/contracts/tokens/nf-token-metadata.sol";
import "../.deps/github.com/nibbstack/erc721/src/contracts/ownership/ownable.sol";

/**
* @title an NFT that is gamified with a payout when burned
* @notice supports timestamp based minting period, contributions to reward pool, and payouts on burn
* @dev an ERC721 compliant token, subclass must implement payout() and mintEligibility()
*/
abstract contract GamifiedNft is
    NFTokenEnumerable,
    NFTokenMetadata,
    Ownable
{
    // Minting period
    uint256 immutable public mintStartTime;
    uint256 immutable public mintEndTime;

    // Total mints and burns
    uint256 public tokensMinted;
    uint256 public tokensBurned;

    // Number of mints per address
    // Does not change when an NFT is transferred
    // Subclass may use this counter for eligibility logic
    mapping(address => uint256) public mintCount;

    // Reward token accepted for contributions and paid out on burn
    IERC20 immutable rewardToken;
    // Total amount added to the pool via contribute()
    uint256 public rewardAmount;
    // Total amount paid via burn()
    uint256 public rewardPaid;

    // List of unique contributor addresses
    address[] public contributors;
    // Minimum contribution accepted, prevent dust amounts
    uint256 public minimumContribution;
    // sum of contributions by address
    mapping(address => uint256) public contributionAmounts;

    /**
    * @param _rewardToken address of an ERC20 token
    * @param _mintStartTime block time after which minting will be allowed
    * @param _mintStartEnd block time before which minting will be allowed
    */
    constructor(
        address _rewardToken,
        uint256 _mintStartTime,
        uint256 _mintEndTime
    ) {
        rewardToken = IERC20(_rewardToken);
        mintStartTime = _mintStartTime;
        mintEndTime = _mintEndTime;
    }

    /**
    * @notice mint an NFT, during mint period and if eligible
    * @dev subclass must override eligibleForMint()
    */
    function mint()
        external
        duringMint
        eligibleForMint
    {
        tokensMinted += 1;
        mintCount[msg.sender] += 1;
        super._mint(msg.sender, tokensMinted);
    }

    /**
    * @notice burn an nft, after mint period is over
    * @dev subclass must override payout()
    * @param _tokenId the NFT token ID to be burned
    */
    function burn(uint256 _tokenId)
        external
        afterMint
    {
        require(idToOwner[_tokenId] == msg.sender, 'Only the NFT owner may burn');

        uint256 amount = payout(_tokenId);
        tokensBurned += 1;
        super._burn(_tokenId);
        rewardToken.transfer(msg.sender, amount);
        rewardPaid += amount;
    }

    /**
    * @notice check the payout of an NFT, if it were the next to be burned
    * @dev provides the payout amount to burn(), also useful to users to check their potential payout
    * @param _tokenId the NFT token ID to get payout amount
    * @return _amount the amount of rewardToken that will be paid the the burner
    */
    function payout(uint256 _tokenId)
        public
        view
        virtual
        returns (uint256 _amount);

    /**
    * @notice convenience function to get mint period and mint current state
    * @return _mintState before minting is allowed, minting is open, or minting has closed
    * @return _burnState burning is not allowed (closed) or allowed (open)
    * @return _mintStartTime may also be retrieved by querying mintStartTime directly
    * @return _mintStartTime may also be retrieved by querying mintEndTime directly
    */
    function state()
        external
        view
        returns (
            string memory _mintState,
            string memory _burnState,
            uint256 _mintStartTime,
            uint256 _mintEndTime
        )
    {
        if(block.timestamp < mintStartTime) {
            _mintState = "before";
            _burnState = "closed";
        }
        else if(block.timestamp < mintEndTime) {
            _mintState = "open";
            _burnState = "closed";
        }
        else {
            _mintState = "closed";
            _burnState = "open";
        }

        return (
            _mintState,
            _burnState,
            mintStartTime,
            mintEndTime
        );
    }

    /**
    * @notice determines eligibility for minting
    * @dev implementation should revert to prevent mint, mint period is checked separately
    */
    modifier eligibleForMint() virtual;

    /// @notice check if the it is during the mint period
    modifier duringMint() {
        require(block.timestamp >= mintStartTime, "Mint has not started");
        require(block.timestamp < mintEndTime, "Mint has ended");
        _;
    }

    /// @notice check if the it is after the mint period
    modifier afterMint() {
        require(block.timestamp >= mintEndTime, "Must wait for mint to end");
        _;
    }

    /**
    * @notice contribute to the reward pool, may also be used by organizers of a gamified nft to the seed the reward pool
    * @param _amount of reward token to contribute, needs allowance for amount
    */
    function contribute(uint256 _amount)
        external
    {
        require(block.timestamp < mintEndTime, "Cannot contribute after mint has ended");
        require(_amount >= minimumContribution, "Amount does not meet minimum contribution");

        rewardToken.transferFrom(msg.sender, address(this), _amount);
        rewardAmount += _amount;

        if(contributionAmounts[msg.sender] == 0) {
            contributors.push(msg.sender);
        }

        contributionAmounts[msg.sender] += _amount;
    }

    /**
    * @notice set the minimum contribution to the reward pool
    * @dev it is recommended for a subclass to set a reasonable value in its constructor
    * @param _minimumContribution the minimum amount to be accepted
    */
    function setMinimumContribution(uint256 _minimumContribution)
        external
        onlyOwner
    {
        minimumContribution = _minimumContribution;
    }

    /**
    * @notice number of contributors
    * @return _count length of contributors array
    */
    function contributorCount()
        external
        view
        returns (uint256 _count)
    {
        return contributors.length;
    }

    /**
    * @notice the current balance of rewardToken held by the contract
    * @return _balance current balance of rewardToken
    */
    function rewardBalance()
        public
        view
        returns (uint256 _balance)
    {
        return rewardToken.balanceOf(address(this));
    }

    /**
    * @notice surplus of the reward token. a surplus is created if rewardToken is directly transferred to the contract (i.e. not via contribute())
    * @return _surplus amount, if any
    */
    function rewardSurplus()
        public
        view
        returns (uint256 _surplus)
    {
        return rewardBalance() - (rewardAmount - rewardPaid);
    }

    /**
    * @notice recover any tokens directly transferred to the contract
    * @dev the rewardToken is a special case, reward funds that are locked in the pool may not be withdrawn
    * @param _token address of the token balance to withdraw
    */
    function recoverToken(address _token)
        external
        onlyOwner
    {
        uint256 amount;
        IERC20 token = IERC20(_token);

        if(_token == address(rewardToken)) {
            amount = rewardSurplus();
        }
        else {
            amount = token.balanceOf(address(this));
        }

        if(amount > 0) {
            token.transfer(msg.sender, amount);
        }
    }

    /**
    * @notice recover any NFTs directly transferred to the contract
    * @param _token address of the token balance to withdraw
    * @param _tokenId the token ID to be withdrawn
    */
    function recoverNft(
        address _nft,
        uint256 _tokenId
    )
        external
        onlyOwner
    {
        ERC721 nft = ERC721(_nft);
        // transferFrom will only succeed for ERC721s, as the ERC20 spec requires
        // An explicit approval/allowance for transferFrom, even from the owner
        nft.transferFrom(address(this), msg.sender, _tokenId);
    }

    /// @inheritdoc NFTokenEnumerable
    function _mint(
        address _to,
        uint256 _tokenId
    )
        internal
        override(NFToken, NFTokenEnumerable)
        virtual
    {
        NFTokenEnumerable._mint(_to, _tokenId);
    }

    /// @inheritdoc NFTokenEnumerable
    function _burn(
        uint256 _tokenId
    )
        internal
        override(NFTokenMetadata, NFTokenEnumerable)
        virtual
    {
        NFTokenEnumerable._burn(_tokenId);
    }

    /// @inheritdoc NFTokenEnumerable
    function _removeNFToken(
        address _from,
        uint256 _tokenId
    )
        internal
        override(NFToken, NFTokenEnumerable)
    {
        NFTokenEnumerable._removeNFToken(_from, _tokenId);
    }

    /// @inheritdoc NFTokenEnumerable
    function _addNFToken(
        address _to,
        uint256 _tokenId
    )
        internal
        override(NFToken, NFTokenEnumerable)
    {
        NFTokenEnumerable._addNFToken(_to, _tokenId);
    }

    /// @inheritdoc NFTokenEnumerable
    function _getOwnerNFTCount(
        address _owner
    )
        internal
        override(NFToken, NFTokenEnumerable)
        view
        returns (uint256)
    {
        return NFTokenEnumerable._getOwnerNFTCount(_owner);
    }

}
