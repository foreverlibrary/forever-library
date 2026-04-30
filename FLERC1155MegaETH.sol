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
            "data:image/svg+xml;base64,PHN2ZyB2ZXJzaW9uPSIxLjIiIHhtbG5zPSJodHRwOi8vd3d3LnczLm9yZy8yMDAwL3N2ZyIgdmlld0JveD0iMCAwIDEwMjQgMTAyNCIgd2lkdGg9IjEwMjQiIGhlaWdodD0iMTAyNCI+Cgk8dGl0bGU+Rm9yZXZlciBMaWJyYXJ5IE1lZ2FFVEg8L3RpdGxlPgoJPHJlY3Qgd2lkdGg9IjEwMjQiIGhlaWdodD0iMTAyNCIgZmlsbD0iI0RGRDlEOSIvPgoJPGcgaWQ9ImxvZ28iPgoJCTxwYXRoIGZpbGw9IiMxOTE5MUEiIGQ9Im02NTkuMzIgMjM1LjQxYy00LjAzLTEuNDgtMjAuNC01LjQ2LTM4LjEyLTQuNi0xNy40OCAwLjg1LTM2LjE1IDUuNDEtNDUuNTQgOS42Mi00Ny45NSAyMS41NC03Mi4yMSA1MS4zOC03Ni42MiA5MS4wM2wtMjIuMTkgMjA0LjY3Yy0zLjQxIDIuMTYtNi44NCA0LjMzLTEwLjE1IDYuNDMtMzAuNzcgMTkuNDQtNTcuMzQgMzYuMjMtNzEuNCA0Ni44NC02NC4yOCA1MC40OC02Ni42OCA4Ny41NS03MC4yNiAxMTguNzYtOC4zMiA3Mi42OSA1MS40NSA4NC4xMSA1Ni43IDg0Ljk3djAuMDhjMC4yOSAwLjA0IDAuNDggMC4wNSAwLjc4IDAuMDkgMzMuNzcgMy43NSA2My45NC0xNS42MyA4Ny44My00MS44OCA1LjI0LTUuMTcgMTAuNTgtMTAuODggMTYuMDMtMTcuNDQgMzEuMDMtMzcuMzkgNDMuMjUtODMuNDMgNDguNDItMTE2LjQ0di0wLjAyYzIuNC0xNS4zMiAzLjI4LTI3Ljg0IDMuODMtMzUuMzV2LTAuMDJsOC42Ni04MHEtMC40OCAwLjIzLTAuOTYgMC40NiAwLjQ4LTAuMjMgMC45Ni0wLjQ2bDAuMDMtMC4yMWMyMy4xNy0xNS40OCA0NC4yOC0zMC40NyA1OS4zMS00My4xNSA5LjU3LTYuMDIgMTUuOTMtMTUuNjkgMTcuODgtMjMuNzQgMy4wOS0xMi43My0wLjg2LTIyLjQyLTUuODEtMjguMzYtNi43My04LjA1LTI4LjUtOC4yOS0yMS43MSAxOC4wMyA0LjA0IDE1LjY1LTEuODQgMjguMS02LjE2IDM0LjY5LTExLjkxIDkuMy0yNi40NiAxOS41OS00Mi4xOCAzMC4yMmwxNS45Mi0xNDYuOTVjMi40Ny0yMi4zIDcuNTktNDUuMDcgMTYuMy02NC4xOSA2LjEyLTEzLjQ0IDIzLjUzLTM3LjQ5IDU2LjE4LTM3LjQ5IDI0LjY2IDAgNDIuNjUgMzQuOSAzNC40MyA1MC4zMi0xMi43OSAyMy45OSA4LjQzIDI4Ljg3IDE2Ljg2IDIyLjYyIDYuMi00LjYgMTIuNDctMTMuMSAxMi4zLTI2LjE5LTAuMTEtOS41Ny03LjYtMzkuOTMtNDEuMzItNTIuMzR6bS0yMDQuNTUgNTA0LjUxYy0xLjY2IDE2LjEyLTIyLjY5IDMwLjk2LTM0LjI4IDM1LjgyLTEyLjEyIDUuMDktMzcuMDQgNS4wMy0zNS40MS04LjY5IDEuNjQtMTMuNzMgMTYuOTgtMTU2LjYyIDE2Ljk4LTE1Ni42MiAwIDAgMS40My04LjYgNC42NC0xMi45NyAyLjk1LTQuMDEgNi44Mi05LjM4IDEzLjAxLTEzLjUgMTQtOS4zMiAzMi4xMS0yMC43NyA1Mi4wNy0zMy4zOSAxLjI0LTAuNzkgMi41Mi0xLjU5IDMuNzktMi4zOS0wLjAzIDAtMTkuMTIgMTc1LjYxLTIwLjggMTkxLjc0eiIvPgoJPC9nPgo8L3N2Zz4K";
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
