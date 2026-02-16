# MOTD Check Script
# Check if motd-news-config is installed on Ubuntu system

echo "Checking MOTD configuration..."
echo "Package status:"
dpkg -l motd-news-config
echo ""
echo "MOTD files:"
ls -la /etc/update-motd.d/ 2>/dev/null || echo "No MOTD directory found"
echo ""
echo "Current MOTD content:"
cat /run/motd.dynamic 2>/dev/null || echo "No dynamic MOTD found"