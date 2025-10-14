// Modern Web App JavaScript
// Handles real-time data fetching and UI updates

let lastUpdateTime = null;

// Fetch and update system status
async function updateStatus() {
    const startTime = performance.now();
    
    try {
        const response = await fetch('/api/status');
        const data = await response.json();
        const endTime = performance.now();
        const responseTime = Math.round(endTime - startTime);
        
        // Update system information
        updateSystemInfo(data.system);
        
        // Update security status
        updateSecurityStatus(data.security);
        
        // Update metrics
        updateMetrics(data.timestamp, responseTime);
        
        // Update health status
        updateHealthStatus(true);
        
        lastUpdateTime = new Date(data.timestamp);
    } catch (error) {
        console.error('Error fetching status:', error);
        updateHealthStatus(false);
    }
}

// Update system information fields
function updateSystemInfo(system) {
    document.getElementById('hostname').textContent = system.hostname || '-';
    document.getElementById('architecture').textContent = system.architecture || '-';
    document.getElementById('kernel').textContent = system.release || '-';
    document.getElementById('cpu-count').textContent = system.cpu_count || '-';
    document.getElementById('uptime').textContent = system.uptime || '-';
    
    if (system.load_average) {
        const loadAvg = system.load_average.map(l => l.toFixed(2)).join(', ');
        document.getElementById('load-avg').textContent = loadAvg;
    }
}

// Update security status badges
function updateSecurityStatus(security) {
    const fipsBadge = document.getElementById('fips-badge');
    const fipsStatus = document.getElementById('fips-status');
    const stigBadge = document.getElementById('stig-badge');
    const stigStatus = document.getElementById('stig-status');
    const cryptoPolicy = document.getElementById('crypto-policy');
    
    // FIPS Status
    if (security.fips_enabled) {
        fipsBadge.classList.add('enabled');
        fipsBadge.classList.remove('disabled');
        fipsStatus.textContent = '✓ Enabled';
    } else {
        fipsBadge.classList.add('disabled');
        fipsBadge.classList.remove('enabled');
        fipsStatus.textContent = '✗ Disabled';
    }
    
    // STIG Status
    if (security.stig_installed) {
        stigBadge.classList.add('enabled');
        stigBadge.classList.remove('disabled');
        stigStatus.textContent = '✓ Installed & Applied';
    } else {
        stigBadge.classList.add('disabled');
        stigBadge.classList.remove('enabled');
        stigStatus.textContent = '✗ Not Installed';
    }
    
    // Crypto Policy
    cryptoPolicy.textContent = security.crypto_policy || 'Unknown';
    const cryptoBadge = document.getElementById('crypto-badge');
    if (security.crypto_policy === 'FIPS') {
        cryptoBadge.classList.add('enabled');
        cryptoBadge.classList.remove('disabled');
    }
}

// Update live metrics
function updateMetrics(timestamp, responseTime) {
    const lastUpdate = new Date(timestamp);
    const timeString = lastUpdate.toLocaleTimeString();
    document.getElementById('last-update').textContent = timeString;
    document.getElementById('response-time').textContent = `${responseTime}ms`;
}

// Update health status indicator
function updateHealthStatus(isHealthy) {
    const healthStatus = document.getElementById('health-status');
    const statusText = healthStatus.querySelector('.status-text');
    
    if (isHealthy) {
        statusText.textContent = 'System Healthy';
        healthStatus.style.background = 'rgba(16, 185, 129, 0.2)';
        healthStatus.style.borderColor = 'rgba(16, 185, 129, 0.3)';
    } else {
        statusText.textContent = 'Connection Error';
        healthStatus.style.background = 'rgba(239, 68, 68, 0.2)';
        healthStatus.style.borderColor = 'rgba(239, 68, 68, 0.3)';
    }
}

// Format timestamp for display
function formatTimestamp(timestamp) {
    const date = new Date(timestamp);
    return date.toLocaleString();
}

// Initialize the app
function init() {
    // Initial status update
    updateStatus();
    
    // Refresh every 10 seconds
    setInterval(updateStatus, 10000);
    
    console.log('CentOS Bootc Demo v4.0 initialized');
}

// Start the app when DOM is ready
if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
} else {
    init();
}

