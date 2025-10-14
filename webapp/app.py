#!/usr/bin/env python3
"""
Modern Demo Web Application for CentOS Bootc Demo
Displays system information, FIPS status, and STIG compliance
"""

from flask import Flask, render_template, jsonify
import subprocess
import os
import socket
import platform
from datetime import datetime

app = Flask(__name__)


def run_command(cmd):
    """Execute a shell command and return output"""
    try:
        result = subprocess.run(
            cmd, shell=True, capture_output=True, text=True, timeout=5
        )
        return result.stdout.strip() if result.returncode == 0 else None
    except Exception:
        return None


def get_fips_status():
    """Check if FIPS mode is enabled"""
    fips_file = "/proc/sys/crypto/fips_enabled"
    try:
        with open(fips_file, "r") as f:
            return f.read().strip() == "1"
    except Exception:
        return False


def get_crypto_policy():
    """Get current cryptographic policy"""
    policy = run_command("update-crypto-policies --show")
    return policy if policy else "Unknown"


def get_stig_info():
    """Check if SCAP Security Guide is installed"""
    ssg_path = "/usr/share/xml/scap/ssg/content"
    return os.path.exists(ssg_path)


def get_bootc_status():
    """Get bootc status information"""
    status = run_command("bootc status --json 2>/dev/null")
    return status if status else None


def get_system_info():
    """Gather system information"""
    return {
        "hostname": socket.gethostname(),
        "os": platform.system(),
        "release": platform.release(),
        "architecture": platform.machine(),
        "python_version": platform.python_version(),
        "uptime": run_command("uptime -p") or "Unknown",
        "load_average": os.getloadavg(),
        "cpu_count": os.cpu_count(),
    }


@app.route("/")
def index():
    """Render main page"""
    return render_template("index.html")


@app.route("/api/status")
def status():
    """API endpoint for system status"""
    system_info = get_system_info()
    fips_enabled = get_fips_status()
    crypto_policy = get_crypto_policy()
    stig_installed = get_stig_info()
    
    return jsonify({
        "timestamp": datetime.now().isoformat(),
        "system": system_info,
        "security": {
            "fips_enabled": fips_enabled,
            "crypto_policy": crypto_policy,
            "stig_installed": stig_installed,
        },
        "bootc_status": get_bootc_status(),
    })


@app.route("/api/health")
def health():
    """Health check endpoint"""
    return jsonify({"status": "healthy", "timestamp": datetime.now().isoformat()})


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080, debug=False)

