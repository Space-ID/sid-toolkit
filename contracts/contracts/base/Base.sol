// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/common/ERC2981.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "./IBase.sol";
import "../registry/ISidRegistry.sol";
import "../admin/ISANN.sol";
import "../access/TldAccessable.sol";

contract Base is ERC721, ERC2981, IBase, TldAccessable {
    using Strings for uint256;

    // A map of expiry times
    mapping(uint256 => uint) expiries;
    // The sid registry
    ISidRegistry public sidRegistry;
    // The namehash of the TLD this registrar owns nodehash(tld.identifier)
    bytes32 public baseNode;
    //uniquely identifies this a TLD on a specific chain
    uint256 public identifier;

    string public tld;

    string public baseUri;

    uint256 public supplyAmount = 0;

    uint256 public constant GRACE_PERIOD = 90 days;
    bytes4 private constant INTERFACE_META_ID =
        bytes4(keccak256("supportsInterface(bytes4)"));
    bytes4 private constant ERC721_ID =
        bytes4(
            keccak256("balanceOf(address)") ^
                keccak256("ownerOf(uint256)") ^
                keccak256("approve(address,uint256)") ^
                keccak256("getApproved(uint256)") ^
                keccak256("setApprovalForAll(address,bool)") ^
                keccak256("isApprovedForAll(address,address)") ^
                keccak256("transferFrom(address,address,uint256)") ^
                keccak256("safeTransferFrom(address,address,uint256)") ^
                keccak256("safeTransferFrom(address,address,uint256,bytes)")
        );
    bytes4 private constant RECLAIM_ID =
        bytes4(keccak256("reclaim(uint256,address)"));
    bytes4 private constant ROYALTY_ID =
        bytes4(keccak256("royaltyInfo(uint256,uint256)"));

    /**
     * v2.1.3 version of _isApprovedOrOwner which calls ownerOf(tokenId) and takes grace period into conarbideration instead of ERC721.ownerOf(tokenId);
     * https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v2.1.3/contracts/token/ERC721/ERC721.sol#L187
     * @dev Returns whether the given spender can transfer a given token ID
     * @param spender address of the spender to query
     * @param tokenId uint256 ID of the token to be transferred
     * @return bool whether the msg.sender is approved for the given token ID,
     *    is an operator of the owner, or is the owner of the token
     */
    function _isApprovedOrOwner(
        address spender,
        uint256 tokenId
    ) internal view override returns (bool) {
        address owner = ownerOf(tokenId);
        return (spender == owner ||
            getApproved(tokenId) == spender ||
            isApprovedForAll(owner, spender));
    }

    constructor(
        ISANN _sann,
        ISidRegistry _sidRegistry,
        uint256 _identifier,
        string memory _tld,
        string memory _baseUri
    ) ERC721("SPACE ID Name Service", _tld) TldAccessable(_sann) {
        sidRegistry = _sidRegistry;
        identifier = _identifier;
        tld = _tld;
        baseNode = keccak256(
            abi.encode(
                keccak256((abi.encode(bytes32(0), bytes32(identifier)))),
                keccak256(bytes(_tld))
            )
        );
        baseUri = _baseUri;
    }

    modifier live() {
        require(sidRegistry.owner(baseNode) == address(this));
        _;
    }

    function totalSupply() external view returns (uint256) {
        return supplyAmount;
    }

    function _mint(address _to, uint256 _tokenId) internal virtual override {
        super._mint(_to, _tokenId);
        supplyAmount = supplyAmount + 1;
    }

    function _burn(uint256 _tokenId) internal virtual override {
        super._burn(_tokenId);
        supplyAmount = supplyAmount - 1;
    }

    /**
     * @dev See {IERC721-transferFrom}.
     */
    function transferFrom(
        address from,
        address to,
        uint256 tokenId
    ) public override(ERC721, IERC721) {
        require(
            _isApprovedOrOwner(_msgSender(), tokenId),
            "ERC721: caller is not approved or owner"
        );

        _transfer(from, to, tokenId);
        sidRegistry.setSubnodeOwner(baseNode, bytes32(tokenId), to);
    }

    /**
     * @dev See {IERC721-safeTransferFrom}.
     */
    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId,
        bytes memory _data
    ) public override(ERC721, IERC721) {
        require(
            _isApprovedOrOwner(_msgSender(), tokenId),
            "ERC721: caller is not approved or owner"
        );
        _safeTransfer(from, to, tokenId, _data);
        sidRegistry.setSubnodeOwner(baseNode, bytes32(tokenId), to);
    }

    /**
     * @dev Gets the owner of the specified token ID. Names become unowned
     *      when their registration expires.
     * @param tokenId uint256 ID of the token to query the owner of
     * @return address currently marked as the owner of the given token ID
     */
    function ownerOf(
        uint256 tokenId
    ) public view override(IERC721, ERC721) returns (address) {
        require(expiries[tokenId] > block.timestamp);
        return super.ownerOf(tokenId);
    }

    // Set the resolver for the TLD this registrar manages.
    function setResolver(address resolver) external override onlyPlatformAdmin {
        sidRegistry.setResolver(baseNode, resolver);
    }

    // Returns the expiration timestamp of the specified id.
    function nameExpires(uint256 id) public view override returns (uint) {
        return expiries[id];
    }

    // Returns true if the specified name is available for registration.
    function available(uint256 id) public view override returns (bool) {
        return expiries[id] + GRACE_PERIOD < block.timestamp;
    }

    /**
     * @dev Register a name.
     * @param id The token ID (keccak256 of the label).
     * @param owner The address that should own the registration.
     * @param duration Duration in seconds for the registration.
     */
    function register(
        uint256 id,
        address owner,
        uint duration
    ) external override returns (uint) {
        return _register(id, owner, duration, true);
    }

    /**
     * @dev Register a name, without modifying the registry.
     * @param id The token ID (keccak256 of the label).
     * @param owner The address that should own the registration.
     * @param duration Duration in seconds for the registration.
     */
    function registerOnly(
        uint256 id,
        address owner,
        uint duration
    ) external returns (uint) {
        return _register(id, owner, duration, false);
    }

    function _register(
        uint256 id,
        address owner,
        uint duration,
        bool updateRegistry
    ) internal live onlyTldController returns (uint) {
        require(available(id));
        require(
            block.timestamp + duration + GRACE_PERIOD >
                block.timestamp + GRACE_PERIOD
        ); // Prevent future overflow

        expiries[id] = block.timestamp + duration;
        if (_exists(id)) {
            // Name was previously owned, and expired
            _burn(id);
        }
        _mint(owner, id);
        if (updateRegistry) {
            sidRegistry.setSubnodeOwner(baseNode, bytes32(id), owner);
        }
        emit NameRegistered(id, owner, block.timestamp + duration);

        return block.timestamp + duration;
    }

    function renew(
        uint256 id,
        uint duration
    ) external override live onlyTldController returns (uint) {
        require(expiries[id] + GRACE_PERIOD >= block.timestamp); // Name must be registered here or in grace period
        require(
            expiries[id] + duration + GRACE_PERIOD > duration + GRACE_PERIOD
        ); // Prevent future overflow
        expiries[id] += duration;
        emit NameRenewed(id, expiries[id]);
        return expiries[id];
    }

    /**
     * @dev Reclaim ownership of a name, if you own it in the registrar.
     */
    function reclaim(uint256 id, address owner) external override live {
        require(_isApprovedOrOwner(msg.sender, id));
        sidRegistry.setSubnodeOwner(baseNode, bytes32(id), owner);
    }

    function supportsInterface(
        bytes4 interfaceID
    ) public pure override(ERC721, ERC2981, IERC165) returns (bool) {
        return
            interfaceID == INTERFACE_META_ID ||
            interfaceID == ERC721_ID ||
            interfaceID == RECLAIM_ID ||
            interfaceID == ROYALTY_ID;
    }

    /**
     * PRIVILEGED MODULE FUNCTION. Sets a new baseURI for all token types.
     */
    function setURI(string memory newURI) external override onlyPlatformAdmin {
        baseUri = newURI;
    }

    function tokenURI(
        uint256 tokenId
    ) public view override returns (string memory) {
        require(
            _exists(tokenId),
            "ERC721Metadata: URI query for nonexistent token"
        );

        string memory baseURI = baseUri;
        return
            bytes(baseURI).length > 0
                ? string(abi.encodePacked(baseURI, Strings.toString(tokenId)))
                : "";
    }

    /**
     * Royalty functions.
     */
    function setDefaultRoyalty(
        address _receiver,
        uint96 _feeNumerator
    ) external onlyTldOwner(identifier) {
        _setDefaultRoyalty(_receiver, _feeNumerator);
    }

    function deleteDefaultRoyalty() external onlyTldOwner(identifier) {
        _deleteDefaultRoyalty();
    }

    function setTokenRoyalty(
        uint256 _tokenId,
        address _receiver,
        uint96 _feeNumerator
    ) external onlyTldOwner(identifier) {
        _setTokenRoyalty(_tokenId, _receiver, _feeNumerator);
    }

    function resetTokenRoyalty(
        uint256 _tokenId
    ) external onlyTldOwner(identifier) {
        _resetTokenRoyalty(_tokenId);
    }
}
