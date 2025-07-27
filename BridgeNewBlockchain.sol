// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;


// Contrat spécifiquement pour Kalichain Avalanche
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

// =============================================================================
// CONTRAT DESTINATION - BLOCKCHAIN KALIS EVM AVALANCHE (Libération des coins natifs KALIS)
// =============================================================================

contract KalisDestinationBridge is Ownable, ReentrancyGuard, Pausable {
    
    // Constantes pour les chaînes
    string public constant CHAIN_ID = "AVAX";
    string public constant SOURCE_CHAIN = "GETH";
    
    // Événements
    event CoinsReleased(
        address indexed recipient,
        uint256 amount,
        uint256 sourceNonce,
        uint256 sourceTimestamp,
        uint256 timestamp,
        bytes32 globalSourceNonce
    );
    
    event CoinsLocked(
        address indexed sender,
        address indexed recipient,
        uint256 amount,
        uint256 nonce,
        uint256 timestamp,
        string destinationChain,
        bytes32 globalNonce
    );
    
    event FeesCollected(
        address indexed sender,
        uint256 feeAmount,
        uint256 timestamp
    );
    
    event RelayerAdded(address indexed relayer);
    event RelayerRemoved(address indexed relayer);
    event ContractFunded(address indexed funder, uint256 amount);
    event BridgeLimitsUpdated(uint256 minAmount, uint256 maxAmount);
    event BridgeFeeUpdated(uint256 newFee);
    event FeesWithdrawn(address indexed owner, uint256 amount);
    event ExpiredNoncesCleaned(uint256 count);
    
    // Variables d'état
    uint256 public nonce;
    uint256 public minBridgeAmount = 100 ether;
    uint256 public maxBridgeAmount = 100000 ether;
    uint256 public totalLocked;              // Total verrouillé pour retours vers Geth
    uint256 public totalReleased;            // Total libéré depuis Geth
    uint256 public totalFeesCollected;       // Total des frais collectés
    uint256 public bridgeFee = 10 ether;
    uint256 public constant NONCE_TIMEOUT = 7 days;
    
    // Mappings
    mapping(bytes32 => bool) public processedReleases; // Utilise des nonces globaux
    mapping(uint256 => uint256) public nonceTimestamps; // Timestamps des nonces locaux
    mapping(address => bool) public authorizedRelayers;
    mapping(address => uint256) public userNonces;
    
    // Modificateurs
    modifier onlyRelayer() {
        require(authorizedRelayers[msg.sender] || msg.sender == owner(), "Not authorized relayer");
        _;
    }
    
    modifier validAmount(uint256 amount) {
        require(amount >= minBridgeAmount, "Amount below minimum");
        require(amount <= maxBridgeAmount, "Amount exceeds maximum");
        _;
    }
    
    modifier localNonceNotExpired(uint256 _nonce) {
        require(
            nonceTimestamps[_nonce] == 0 || 
            block.timestamp <= nonceTimestamps[_nonce] + NONCE_TIMEOUT,
            "Local nonce expired"
        );
        _;
    }
    
    modifier crossChainNonceNotExpired(uint256 _sourceTimestamp) {
        require(
            _sourceTimestamp > 0 && 
            block.timestamp <= _sourceTimestamp + NONCE_TIMEOUT,
            "Cross-chain nonce expired"
        );
        _;
    }
    
    constructor() Ownable(msg.sender) {
        // Le déployeur devient automatiquement un relayer autorisé
        authorizedRelayers[msg.sender] = true;
        
        //  AJOUT AUTOMATIQUE DU RELAYER POUR LE BRIDGE
        authorizedRelayers[0xb2c9d4B80817c05c4ECeACF0d1D18dB0735204Df] = true;
    }
    
    /**
     * @notice Génère un nonce global unique pour éviter les collisions inter-chaînes
     */
    function _generateGlobalNonce(uint256 localNonce) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(CHAIN_ID, localNonce));
    }
    
    /**
     * @notice Génère un nonce global pour une source externe
     */
    function _generateSourceGlobalNonce(uint256 sourceNonce) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(SOURCE_CHAIN, sourceNonce));
    }
    
    /**
     * @notice Libère les coins natifs KALIS depuis Geth
     * @param recipient Destinataire des coins
     * @param amount Montant à libérer
     * @param sourceNonce Nonce de la transaction source (depuis Geth)
     * @param sourceTimestamp Timestamp de la transaction source pour validation d'expiration
     */
    function releaseCoins(
        address payable recipient,
        uint256 amount,
        uint256 sourceNonce,
        uint256 sourceTimestamp
    ) 
        external 
        onlyRelayer 
        nonReentrant 
        whenNotPaused
        crossChainNonceNotExpired(sourceTimestamp)
    {
        require(recipient != address(0), "Invalid recipient");
        require(amount > 0, "Amount must be positive");
        require(sourceTimestamp > 0, "Invalid source timestamp");
        
        bytes32 globalSourceNonce = _generateSourceGlobalNonce(sourceNonce);
        require(!processedReleases[globalSourceNonce], "Transaction already processed");
        
        // S'assurer qu'il y a assez de fonds disponibles (hors fonds verrouillés et frais)
        uint256 availableBalance = address(this).balance - totalLocked - totalFeesCollected;
        require(availableBalance >= amount, "Insufficient available balance");
        
        processedReleases[globalSourceNonce] = true;
        totalReleased += amount;
        
        recipient.transfer(amount);
        
        emit CoinsReleased(
            recipient, 
            amount, 
            sourceNonce, 
            sourceTimestamp, 
            block.timestamp,
            globalSourceNonce
        );
    }
    
    /**
     * @notice Verrouille les coins pour un bridge retour vers Geth
     * @param recipient Adresse destinataire sur KALIS Geth
     */
    function lockCoinsForReturn(address recipient) 
        external 
        payable 
        nonReentrant 
        whenNotPaused 
        validAmount(msg.value)
    {
        require(recipient != address(0), "Invalid recipient");
        require(msg.value > bridgeFee, "Amount must cover bridge fee");
        
        uint256 bridgeAmount = msg.value - bridgeFee;
        bytes32 globalNonce = _generateGlobalNonce(nonce);
        
        // Mise à jour des totaux
        totalLocked += bridgeAmount;
        totalFeesCollected += bridgeFee;
        
        // Enregistrement du timestamp pour les nonces locaux
        nonceTimestamps[nonce] = block.timestamp;
        
        emit CoinsLocked(
            msg.sender,
            recipient,
            bridgeAmount,
            nonce,
            block.timestamp,
            "KALIS-GETH",
            globalNonce
        );
        
        emit FeesCollected(msg.sender, bridgeFee, block.timestamp);
        
        nonce++;
        userNonces[msg.sender]++;
    }
    
    /**
     * @notice Ajoute un relayer autorisé
     */
    function addRelayer(address relayer) external onlyOwner {
        require(relayer != address(0), "Invalid relayer address");
        require(!authorizedRelayers[relayer], "Relayer already authorized");
        authorizedRelayers[relayer] = true;
        emit RelayerAdded(relayer);
    }
    
    /**
     * @notice Retire un relayer autorisé
     */
    function removeRelayer(address relayer) external onlyOwner {
        require(authorizedRelayers[relayer], "Relayer not authorized");
        authorizedRelayers[relayer] = false;
        emit RelayerRemoved(relayer);
    }
    
    /**
     * @notice Met à jour les limites de bridge
     */
    function updateBridgeLimits(uint256 _minAmount, uint256 _maxAmount) external onlyOwner {
        require(_minAmount > 0, "Min amount must be positive");
        require(_maxAmount > _minAmount, "Max must be greater than min");
        require(_minAmount > bridgeFee, "Min amount must be greater than bridge fee");
        
        minBridgeAmount = _minAmount;
        maxBridgeAmount = _maxAmount;
        
        emit BridgeLimitsUpdated(_minAmount, _maxAmount);
    }
    
    /**
     * @notice Met à jour les frais de bridge
     */
    function updateBridgeFee(uint256 _bridgeFee) external onlyOwner {
        require(_bridgeFee < minBridgeAmount, "Fee too high");
        bridgeFee = _bridgeFee;
        emit BridgeFeeUpdated(_bridgeFee);
    }
    
    /**
     * @notice Retire les frais accumulés
     */
    function withdrawFees() external onlyOwner {
        require(totalFeesCollected > 0, "No fees to withdraw");
        require(address(this).balance >= totalFeesCollected, "Insufficient balance for fees");
        
        uint256 feesToWithdraw = totalFeesCollected;
        totalFeesCollected = 0;
        
        payable(owner()).transfer(feesToWithdraw);
        emit FeesWithdrawn(owner(), feesToWithdraw);
    }
    
    /**
     * @notice Nettoie les nonces locaux expirés pour économiser du gas
     */
    function cleanExpiredLocalNonces(uint256[] calldata expiredNonces) external onlyOwner {
        uint256 cleanedCount = 0;
        for (uint256 i = 0; i < expiredNonces.length; i++) {
            uint256 nonceToClean = expiredNonces[i];
            if (nonceTimestamps[nonceToClean] != 0 && 
                block.timestamp > nonceTimestamps[nonceToClean] + NONCE_TIMEOUT) {
                delete nonceTimestamps[nonceToClean];
                cleanedCount++;
            }
        }
        emit ExpiredNoncesCleaned(cleanedCount);
    }
    
    /**
     * @notice Finance le contrat avec des coins natifs KALIS
     */
    function fundContract() external payable onlyOwner {
        require(msg.value > 0, "Must send some KALIS");
        emit ContractFunded(msg.sender, msg.value);
    }
    
    /**
     * @notice Retire des fonds en cas d'urgence (hors fonds verrouillés et frais)
     */
    function emergencyWithdraw(uint256 amount) external onlyOwner {
        uint256 availableForWithdraw = address(this).balance - totalLocked - totalFeesCollected;
        require(amount <= availableForWithdraw, "Cannot withdraw locked/fee funds");
        payable(owner()).transfer(amount);
    }
    
    /**
     * @notice Pause le contrat
     */
    function pause() external onlyOwner {
        _pause();
    }
    
    /**
     * @notice Dépause le contrat
     */
    function unpause() external onlyOwner {
        _unpause();
    }
    
    /**
     * @notice Permet de recevoir des KALIS natifs pour financer le contrat
     */
    receive() external payable onlyOwner {
        emit ContractFunded(msg.sender, msg.value);
    }
    
    /**
     * @notice Obtient le solde du contrat
     */
    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }
    
    /**
     * @notice Obtient les fonds disponibles pour les releases
     */
    function getAvailableForRelease() external view returns (uint256) {
        return address(this).balance - totalLocked - totalFeesCollected;
    }
    
    /**
     * @notice Vérifie si un nonce global a été traité
     */
    function isGlobalNonceProcessed(bytes32 globalNonce) external view returns (bool) {
        return processedReleases[globalNonce];
    }
    
    /**
     * @notice Génère le nonce global pour un nonce local donné (utilitaire)
     */
    function getGlobalNonce(uint256 localNonce) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(CHAIN_ID, localNonce));
    }
    
    /**
     * @notice Vérifie la configuration du bridge après déploiement
     */
    function checkBridgeConfig() external view returns (
        address _owner,
        bool _deployerIsRelayer,
        bool _targetRelayerIsAuthorized,
        uint256 _contractBalance,
        string memory _status
    ) {
        address targetRelayer = 0xb2c9d4B80817c05c4ECeACF0d1D18dB0735204Df;
        bool deployerRelayer = authorizedRelayers[owner()];
        bool targetRelayerAuth = authorizedRelayers[targetRelayer];
        
        string memory status = "OK";
        if (owner() == address(0)) status = "ERROR: No owner";
        else if (!deployerRelayer) status = "WARNING: Deployer not relayer";
        else if (!targetRelayerAuth) status = "ERROR: Target relayer not authorized";
        
        return (
            owner(),
            deployerRelayer,
            targetRelayerAuth,
            address(this).balance,
            status
        );
    }
    
    /**
     * @notice Obtient les statistiques du bridge
     */
    function getBridgeStats() external view returns (
        uint256 _totalLocked,
        uint256 _totalReleased,
        uint256 _totalFeesCollected,
        uint256 _availableBalance
    ) {
        return (
            totalLocked,
            totalReleased,
            totalFeesCollected,
            address(this).balance - totalLocked - totalFeesCollected
        );
    }
}
