// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Base64.sol";
import "@openzeppelin/contracts/token/common/ERC2981.sol";

interface IExternalRenderer {
    function uri(uint256 tokenId) external view returns (string memory);
}

/// @title Forever Library
/// @notice A fully immutable, non-upgradeable ERC1155 contract with open minting and permanent metadata.
contract ForeverLibrary is ERC1155, ReentrancyGuard, ERC2981 {
    string public constant VERSION = "1.0.0";
    uint256 private constant MAX_URI_LENGTH = 65535;
    address public immutable DEPLOYER;

    bytes4 private constant ERC7572_INTERFACE_ID = 0xe8a3d485;

    uint256 private _currentTokenTypeId;

    string private _collectionName;
    string private _collectionDescription;
    string private _collectionImage;

    struct MintData {
        address creator; // 20 bytes
        uint64 timestamp; // 8 bytes
        uint64 blockNumber; // 8 bytes
        bytes32 metadataHash; // 32 bytes
        string tokenURI; // dynamic
        uint256 maxSupply; // maximum supply for this token type
        uint256 currentSupply; // current supply minted
        bool isSoulbound;
    }

    mapping(uint256 => MintData) private _mintData;

    mapping(uint256 => bool) public usesExternalRenderer;
    mapping(uint256 => address) public externalRendererAddresses;

    event TokenTypeMinted(
        address indexed creator,
        uint256 indexed tokenTypeId,
        string tokenURI,
        bytes32 metadataHash,
        uint256 timestamp,
        uint256 blockNumber,
        string title,
        string mediaType,
        uint256 amount,
        uint256 maxSupply
    );

    event RoyaltyUpdated(uint256 indexed tokenTypeId, uint96 royaltyPercentage);

    event ExternalRendererSet(uint256 indexed tokenTypeId, address indexed renderer, address indexed creator);
    event ExternalRendererToggled(uint256 indexed tokenTypeId, bool enabled, address indexed creator);
    event TokenSoulbound(uint256 indexed tokenTypeId, address indexed creator);
    event TokenURIUpdated(uint256 indexed tokenTypeId, string newURI, bytes32 newHash);

    error EmptyURI();
    error URITooLong();
    error EtherNotAccepted();
    error NotTokenCreator();
    error InvalidRendererAddress();
    error MetadataLocked();
    error TokenTypeNotFound();
    error EmptyTitle();
    error EmptyMediaType();
    error InvalidRoyaltyPercentage();
    error SupplyMismatch();
    error InvalidAmount();
    error ZeroAmount();

    error TokenIsSoulbound();

    constructor() ERC1155("") {
        DEPLOYER = msg.sender;

        _currentTokenTypeId = 1;

        _collectionName = "Forever Library";
        _collectionDescription =
            "A fully immutable, non-upgradeable NFT contract with open minting and permanent metadata.";

        _collectionImage =
            "data:image/svg+xml;base64,PHN2ZyB2ZXJzaW9uPSIxLjIiIHhtbG5zPSJodHRwOi8vd3d3LnczLm9yZy8yMDAwL3N2ZyIgdmlld0JveD0iMCAwIDEwMjQgMTAyNCIgd2lkdGg9IjEwMjQiIGhlaWdodD0iMTAyNCI+Cgk8dGl0bGU+Rm9yZXZlciBMaWJyYXJ5IEV0aGVyZXVtPC90aXRsZT4KCTxyZWN0IHdpZHRoPSIxMDI0IiBoZWlnaHQ9IjEwMjQiIGZpbGw9IiM3QjNGRTQiLz4KCTxnIGlkPSJsb2dvIj4KCQk8cGF0aCBmaWxsPSIjZmZmZmZmIiBkPSJtNjU5LjMyIDIzNS40MWMtNC4wMy0xLjQ4LTIwLjQtNS40Ni0zOC4xMi00LjYtMTcuNDggMC44NS0zNi4xNSA1LjQxLTQ1LjU0IDkuNjItNDcuOTUgMjEuNTQtNzIuMjEgNTEuMzgtNzYuNjIgOTEuMDNsLTIyLjE5IDIwNC42N2MtMy40MSAyLjE2LTYuODQgNC4zMy0xMC4xNSA2LjQzLTMwLjc3IDE5LjQ0LTU3LjM0IDM2LjIzLTcxLjQgNDYuODQtNjQuMjggNTAuNDgtNjYuNjggODcuNTUtNzAuMjYgMTE4Ljc2LTguMzIgNzIuNjkgNTEuNDUgODQuMTEgNTYuNyA4NC45N3YwLjA4YzAuMjkgMC4wNCAwLjQ4IDAuMDUgMC43OCAwLjA5IDMzLjc3IDMuNzUgNjMuOTQtMTUuNjMgODcuODMtNDEuODggNS4yNC01LjE3IDEwLjU4LTEwLjg4IDE2LjAzLTE3LjQ0IDMxLjAzLTM3LjM5IDQzLjI1LTgzLjQzIDQ4LjQyLTExNi40NHYtMC4wMmMyLjQtMTUuMzIgMy4yOC0yNy44NCAzLjgzLTM1LjM1di0wLjAybDguNjYtODBxLTAuNDggMC4yMy0wLjk2IDAuNDYgMC40OC0wLjIzIDAuOTYtMC40NmwwLjAzLTAuMjFjMjMuMTctMTUuNDggNDQuMjgtMzAuNDcgNTkuMzEtNDMuMTUgOS41Ny02LjAyIDE1LjkzLTE1LjY5IDE3Ljg4LTIzLjc0IDMuMDktMTIuNzMtMC44Ni0yMi40Mi01LjgxLTI4LjM2LTYuNzMtOC4wNS0yOC41LTguMjktMjEuNzEgMTguMDMgNC4wNCAxNS42NS0xLjg0IDI4LjEtNi4xNiAzNC42OS0xMS45MSA5LjMtMjYuNDYgMTkuNTktNDIuMTggMzAuMjJsMTUuOTItMTQ2Ljk1YzIuNDctMjIuMyA3LjU5LTQ1LjA3IDE2LjMtNjQuMTkgNi4xMi0xMy40NCAyMy41My0zNy40OSA1Ni4xOC0zNy40OSAyNC42NiAwIDQyLjY1IDM0LjkgMzQuNDMgNTAuMzItMTIuNzkgMjMuOTkgOC40MyAyOC44NyAxNi44NiAyMi42MiA2LjItNC42IDEyLjQ3LTEzLjEgMTIuMy0yNi4xOS0wLjExLTkuNTctNy42LTM5LjkzLTQxLjMyLTUyLjM0em0tMjA0LjU1IDUwNC41MWMtMS42NiAxNi4xMi0yMi42OSAzMC45Ni0zNC4yOCAzNS44Mi0xMi4xMiA1LjA5LTM3LjA0IDUuMDMtMzUuNDEtOC42OSAxLjY0LTEzLjczIDE2Ljk4LTE1Ni42MiAxNi45OC0xNTYuNjIgMCAwIDEuNDMtOC42IDQuNjQtMTIuOTcgMi45NS00LjAxIDYuODItOS4zOCAxMy4wMS0xMy41IDE0LTkuMzIgMzIuMTEtMjAuNzcgNTIuMDctMzMuMzkgMS4yNC0wLjc5IDIuNTItMS41OSAzLjc5LTIuMzktMC4wMyAwLTE5LjEyIDE3NS42MS0yMC44IDE5MS43NHoiLz4KCTwvZz4KPC9zdmc+Cg==";
    }

    modifier onlyTokenCreator(uint256 tokenTypeId) {
        if (_mintData[tokenTypeId].creator != msg.sender) revert NotTokenCreator();
        _;
    }

    function isSoulbound(uint256 tokenTypeId) external view returns (bool) {
        if (_mintData[tokenTypeId].creator == address(0)) revert TokenTypeNotFound();
        return _mintData[tokenTypeId].isSoulbound;
    }

    function _emitTokenTypeMinted(
        uint256 tokenTypeId,
        string calldata title,
        string calldata mediaType
    ) internal {
        MintData storage d = _mintData[tokenTypeId];
        emit TokenTypeMinted(
            d.creator,
            tokenTypeId,
            d.tokenURI,
            d.metadataHash,
            d.timestamp,
            d.blockNumber,
            title,
            mediaType,
            d.currentSupply,
            d.maxSupply
        );
    }

    function mintSoulbound(
        string calldata finalTokenURI,
        string calldata title,
        string calldata mediaType,
        uint96 royaltyPercentage
    ) external nonReentrant {
        if (bytes(finalTokenURI).length == 0) revert EmptyURI();
        if (bytes(finalTokenURI).length > MAX_URI_LENGTH) revert URITooLong();
        if (bytes(title).length == 0) revert EmptyTitle();
        if (bytes(mediaType).length == 0) revert EmptyMediaType();
        if (royaltyPercentage > 10000) revert InvalidRoyaltyPercentage();

        uint256 tokenTypeId = _currentTokenTypeId;
        unchecked {
            _currentTokenTypeId++;
        }

        bytes32 metadataHash = keccak256(bytes(finalTokenURI));

        _mintData[tokenTypeId] = MintData({
            creator: msg.sender,
            timestamp: uint64(block.timestamp),
            blockNumber: uint64(block.number),
            metadataHash: metadataHash,
            tokenURI: finalTokenURI,
            maxSupply: 1,
            currentSupply: 1,
            isSoulbound: true
        });

        _setTokenRoyalty(tokenTypeId, msg.sender, royaltyPercentage);

        _mint(msg.sender, tokenTypeId, 1, "");

        _emitTokenTypeMinted(tokenTypeId, title, mediaType);

        emit TokenSoulbound(tokenTypeId, msg.sender);
    }

    function mint(
        string calldata finalTokenURI,
        string calldata title,
        string calldata mediaType,
        uint96 royaltyPercentage,
        uint256 amount,
        uint256 maxSupply
    ) external nonReentrant {
        if (bytes(finalTokenURI).length == 0) revert EmptyURI();
        if (bytes(finalTokenURI).length > MAX_URI_LENGTH) revert URITooLong();
        if (bytes(title).length == 0) revert EmptyTitle();
        if (bytes(mediaType).length == 0) revert EmptyMediaType();
        if (royaltyPercentage > 10000) revert InvalidRoyaltyPercentage(); // Max 100%
        if (amount == 0) revert ZeroAmount();
        if (maxSupply == 0) revert InvalidAmount();
        if (amount != maxSupply) revert SupplyMismatch();

        uint256 tokenTypeId = _currentTokenTypeId;
        unchecked {
            _currentTokenTypeId++;
        }

        bytes32 metadataHash = keccak256(bytes(finalTokenURI));

        _mintData[tokenTypeId] = MintData({
            creator: msg.sender,
            timestamp: uint64(block.timestamp),
            blockNumber: uint64(block.number),
            metadataHash: metadataHash,
            tokenURI: finalTokenURI,
            maxSupply: maxSupply,
            currentSupply: amount,
            isSoulbound: false
        });

        _setTokenRoyalty(tokenTypeId, msg.sender, royaltyPercentage);

        _mint(msg.sender, tokenTypeId, amount, "");

        _emitTokenTypeMinted(tokenTypeId, title, mediaType);
    }

    function updateTokenRoyalty(uint256 tokenTypeId, uint96 royaltyPercentage) external onlyTokenCreator(tokenTypeId) {
        if (royaltyPercentage > 10000) revert InvalidRoyaltyPercentage(); // Max 100%

        _setTokenRoyalty(tokenTypeId, _mintData[tokenTypeId].creator, royaltyPercentage);
        emit RoyaltyUpdated(tokenTypeId, royaltyPercentage);
    }

    function getMintData(uint256 _tokenTypeId) public view returns (MintData memory) {
        if (_mintData[_tokenTypeId].creator == address(0)) revert TokenTypeNotFound();
        return _mintData[_tokenTypeId];
    }

    function setTokenURI(uint256 tokenTypeId, string calldata _uri) external onlyTokenCreator(tokenTypeId) {
        if (block.timestamp > _mintData[tokenTypeId].timestamp + 24 hours) revert MetadataLocked();
        if (bytes(_uri).length == 0) revert EmptyURI();
        if (bytes(_uri).length > MAX_URI_LENGTH) revert URITooLong();

        bytes32 newHash = keccak256(bytes(_uri));
        _mintData[tokenTypeId].tokenURI = _uri;
        _mintData[tokenTypeId].metadataHash = newHash;

        emit URI(_uri, tokenTypeId);
        emit TokenURIUpdated(tokenTypeId, _uri, newHash);
    }

    function setBlankURIForRenderer(uint256 tokenTypeId) external onlyTokenCreator(tokenTypeId) {
        if (block.timestamp > _mintData[tokenTypeId].timestamp + 24 hours) revert MetadataLocked();

        _mintData[tokenTypeId].tokenURI = "";
        _mintData[tokenTypeId].metadataHash = bytes32(0); // Signal external renderer mode

        emit URI("", tokenTypeId);
    }

    function totalTokenTypes() public view returns (uint256) {
        if (_currentTokenTypeId == 0) return 0;
        return _currentTokenTypeId - 1;
    }

    function metadataLockTime(uint256 tokenTypeId) external view returns (uint256) {
        if (_mintData[tokenTypeId].creator == address(0)) revert TokenTypeNotFound();
        uint256 lockTime = _mintData[tokenTypeId].timestamp + 24 hours;
        return block.timestamp >= lockTime ? 0 : lockTime - block.timestamp;
    }

    function totalSupply(uint256 tokenTypeId) public view returns (uint256) {
        if (_mintData[tokenTypeId].creator == address(0)) revert TokenTypeNotFound();
        return _mintData[tokenTypeId].currentSupply;
    }

    function getMaxSupply(uint256 tokenTypeId) public view returns (uint256) {
        if (_mintData[tokenTypeId].creator == address(0)) revert TokenTypeNotFound();
        return _mintData[tokenTypeId].maxSupply;
    }

    function setExternalRenderer(uint256 tokenTypeId, address renderer) external onlyTokenCreator(tokenTypeId) {
        if (renderer == address(0)) revert InvalidRendererAddress();
        if (block.timestamp > _mintData[tokenTypeId].timestamp + 24 hours) revert MetadataLocked();

        externalRendererAddresses[tokenTypeId] = renderer;
        emit ExternalRendererSet(tokenTypeId, renderer, msg.sender);
    }

    function toggleExternalRenderer(uint256 tokenTypeId, bool enabled) external onlyTokenCreator(tokenTypeId) {
        if (block.timestamp > _mintData[tokenTypeId].timestamp + 24 hours) revert MetadataLocked();

        usesExternalRenderer[tokenTypeId] = enabled;
        emit ExternalRendererToggled(tokenTypeId, enabled, msg.sender);
    }

    function uri(uint256 tokenTypeId) public view override returns (string memory) {
        if (_mintData[tokenTypeId].creator == address(0)) revert TokenTypeNotFound();

        if (usesExternalRenderer[tokenTypeId] && externalRendererAddresses[tokenTypeId] != address(0)) {
            return IExternalRenderer(externalRendererAddresses[tokenTypeId]).uri(tokenTypeId);
        }

        return _mintData[tokenTypeId].tokenURI;
    }

    function contractURI() public view returns (string memory) {
        return string(
            abi.encodePacked(
                "data:application/json;base64,",
                Base64.encode(
                    bytes(
                        abi.encodePacked(
                            '{"name":"',
                            _collectionName,
                            '","description":"',
                            _collectionDescription,
                            '","image":"',
                            _collectionImage,
                            '"}'
                        )
                    )
                )
            )
        );
    }

    function _update(address from, address to, uint256[] memory ids, uint256[] memory values)
        internal
        override(ERC1155)
    {
        // Block all post-mint movement of soulbound tokens (transfers and burns)
        if (from != address(0)) {
            uint256 length = ids.length;
            for (uint256 i = 0; i < length; i++) {
                if (_mintData[ids[i]].isSoulbound) {
                    revert TokenIsSoulbound();
                }
            }
        }

        super._update(from, to, ids, values);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC1155, ERC2981)
        returns (bool)
    {
        return interfaceId == ERC7572_INTERFACE_ID // ERC-7572 (contractURI)
            || super.supportsInterface(interfaceId);
    }

    receive() external payable {
        revert EtherNotAccepted();
    }

    fallback() external payable {
        revert EtherNotAccepted();
    }
}
