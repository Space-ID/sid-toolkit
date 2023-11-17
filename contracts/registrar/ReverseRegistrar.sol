// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";

import "../registry/SidRegistry.sol";
import "./IReverseRegistrar.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

abstract contract ReverseResolver {
    function setName(bytes32 node, string memory name) public virtual;

    function setTldName(
        bytes32 node,
        uint256 identifier,
        string memory name
    ) public virtual;
}

bytes32 constant lookup = 0x3031323334353637383961626364656600000000000000000000000000000000;

bytes32 constant ADDR_REVERSE_NODE = 0x91d1777781884d03a6757a803996e38de2a42967fb37eeaca72729271025a9e2;

// namehash('addr.reverse')

contract ReverseRegistrar is Ownable, IReverseRegistrar, Initializable {
    SidRegistry public sid;
    ReverseResolver public defaultResolver;
    mapping(address => bool) public controllers;

    event ReverseClaimed(address indexed addr, bytes32 indexed node);
    event ControllerChanged(address indexed controller, bool enabled);

    /**
     * @dev Constructor
     * @param owner The address of the owner.
     */
    constructor(address owner) {
        transferOwnership(owner);
    }

    function initialize (SidRegistry sidAddr) public initializer onlyOwner {
        sid = sidAddr;
    }

    modifier authorised(address addr) {
        require(
            addr == msg.sender ||
                controllers[msg.sender] ||
                sid.isApprovedForAll(addr, msg.sender) ||
                ownsContract(addr),
            "ReverseRegistrar: Caller is not a controller or authorised by address or the address itself"
        );
        _;
    }

    function setDefaultResolver(address resolver) public override onlyOwner {
        require(
            address(resolver) != address(0),
            "ReverseRegistrar: Resolver address must not be 0"
        );
        defaultResolver = ReverseResolver(resolver);
    }

    /**
     * @dev Transfers ownership of the reverse sid record associated with the
     *      calling account.
     * @param owner The address to set as the owner of the reverse record in sid.
     * @return The sid node hash of the reverse record.
     */
    function claim(address owner) public override returns (bytes32) {
        return claimForAddr(msg.sender, owner, address(defaultResolver));
    }

    /**
     * @dev Transfers ownership of the reverse sid record associated with the
     *      calling account.
     * @param addr The reverse record to set
     * @param owner The address to set as the owner of the reverse record in sid.
     * @return The sid node hash of the reverse record.
     */
    function claimForAddr(
        address addr,
        address owner,
        address resolver
    ) public override authorised(addr) returns (bytes32) {
        bytes32 labelHash = sha3HexAddress(addr);
        bytes32 reverseNode = keccak256(
            abi.encodePacked(ADDR_REVERSE_NODE, labelHash)
        );
        emit ReverseClaimed(addr, reverseNode);
        sid.setSubnodeRecord(ADDR_REVERSE_NODE, labelHash, owner, resolver, 0);
        return reverseNode;
    }

    /**
     * @dev Transfers ownership of the reverse sid record associated with the
     *      calling account.
     * @param owner The address to set as the owner of the reverse record in sid.
     * @param resolver The address of the resolver to set; 0 to leave unchanged.
     * @return The sid node hash of the reverse record.
     */
    function claimWithResolver(
        address owner,
        address resolver
    ) public override returns (bytes32) {
        return claimForAddr(msg.sender, owner, resolver);
    }

    /**
     * @dev Sets the `name()` record for the reverse sid record associated with
     * the calling account. First updates the resolver to the default reverse
     * resolver if necessary.
     * @param name The name to set for this address.
     * @return The sid node hash of the reverse record.
     */
    function setName(string memory name) public override returns (bytes32) {
        return
            setNameForAddr(
                msg.sender,
                msg.sender,
                address(defaultResolver),
                name
            );
    }

    /**
     * @dev Sets the `name()` record for the reverse sid record associated with
     * the account provided. First updates the resolver to the default reverse
     * resolver if necessary.
     * Only callable by controllers and authorised users
     * @param addr The reverse record to set
     * @param owner The owner of the reverse node
     * @param name The name to set for this address.
     * @return The sid node hash of the reverse record.
     */
    function setNameForAddr(
        address addr,
        address owner,
        address resolver,
        string memory name
    ) public override returns (bytes32) {
        bytes32 _node = claimForAddr(addr, owner, resolver);
        ReverseResolver(resolver).setName(_node, name);
        return _node;
    }

    /**
     * @dev Sets the `tldName()` record for the reverse sid record associated with
     * the calling account. First updates the resolver to the default reverse
     * resolver if necessary.
     * @param identifier The identifier of TLD.
     * @param name The name to set for this address.
     * @return The sid node hash of the reverse record.
     */
    function setTldName(
        uint256 identifier,
        string memory name
    ) public override returns (bytes32) {
        return
            setTldNameForAddr(
                msg.sender,
                msg.sender,
                address(defaultResolver),
                identifier,
                name
            );
    }

    /**
     * @dev Sets the `tldName()` record for the reverse sid record associated with
     * the account provided. First updates the resolver to the default reverse
     * resolver if necessary.
     * Only callable by controllers and authorised users
     * @param addr The reverse record to set
     * @param owner The owner of the reverse node
     * @param identifier The identifier of TLD.
     * @param name The name to set for this address.
     * @return The sid node hash of the reverse record.
     */
    function setTldNameForAddr(
        address addr,
        address owner,
        address resolver,
        uint256 identifier,
        string memory name
    ) public override returns (bytes32) {
        bytes32 _node = claimForAddr(addr, owner, resolver);
        ReverseResolver(resolver).setTldName(_node, identifier, name);
        return _node;
    }

    /**
     * @dev Sets both the `tldName()` and the `name()` records and
     * for the reverse sid record associated with the account provided.
     * First updates the resolver to the default reverse resolver if necessary.
     * Only callable by controllers and authorised users
     * @param addr The reverse record to set
     * @param owner The owner of the reverse node
     * @param name The name to set for this address.
     * @param identifier The identifier of TLD.
     * @param name The tld name to set for this address.
     * @return The sid node hash of the reverse record.
     */
    function setAllNamesForAddr(
        address addr,
        address owner,
        address resolver,
        string memory name,
        uint256 identifier,
        string memory tldName
    ) public override returns (bytes32) {
        bytes32 _node = claimForAddr(addr, owner, resolver);
        ReverseResolver(resolver).setName(_node, name);
        ReverseResolver(resolver).setTldName(_node, identifier, tldName);
        return _node;
    }

    /**
     * @dev Returns the node hash for a given account's reverse records.
     * @param addr The address to hash
     * @return The sid node hash.
     */
    function node(address addr) public pure override returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(ADDR_REVERSE_NODE, sha3HexAddress(addr))
            );
    }

    /**
     * @dev An optimised function to compute the sha3 of the lower-case
     *      hexadecimal representation of an Ethereum address.
     * @param addr The address to hash
     * @return ret The SHA3 hash of the lower-case hexadecimal encoding of the
     *         input address.
     */
    function sha3HexAddress(address addr) private pure returns (bytes32 ret) {
        assembly {
            for {
                let i := 40
            } gt(i, 0) {

            } {
                i := sub(i, 1)
                mstore8(i, byte(and(addr, 0xf), lookup))
                addr := div(addr, 0x10)
                i := sub(i, 1)
                mstore8(i, byte(and(addr, 0xf), lookup))
                addr := div(addr, 0x10)
            }

            ret := keccak256(0, 40)
        }
    }

    function ownsContract(address addr) internal view returns (bool) {
        try Ownable(addr).owner() returns (address owner) {
            return owner == msg.sender;
        } catch {
            return false;
        }
    }

    modifier onlyController() {
        require(
            controllers[msg.sender],
            "Controllable: Caller is not a controller"
        );
        _;
    }

    function setController(address controller, bool enabled) public onlyOwner {
        controllers[controller] = enabled;
        emit ControllerChanged(controller, enabled);
    }
}