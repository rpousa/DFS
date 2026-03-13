#!/bin/bash
# diagnose-connection.sh - Run on Machine 1

MACHINE2_IP="192.168.0.243"
TEST_PORT="38412"

echo "=== Connection Diagnostic Tool ==="
echo ""

echo "1. Port Binding Check:"
sudo netstat -tlnp | grep $TEST_PORT

echo ""
echo "2. Container Status:"
docker ps | grep amf

echo ""
echo "3. Container Actually Listening:"
docker exec amf ss -tlnp 2>/dev/null | grep $TEST_PORT || echo "NOT LISTENING IN CONTAINER!"

echo ""
echo "4. Firewall Status:"
sudo ufw status 2>/dev/null || echo "ufw not installed"

echo ""
echo "5. Docker NAT Rules:"
sudo iptables -t nat -L DOCKER -n | grep $TEST_PORT

echo ""
echo "6. IP Forwarding:"
cat /proc/sys/net/ipv4/ip_forward

echo ""
echo "7. Docker Bridge:"
ip addr show br-core 2>/dev/null || echo "br-core not found"

echo ""
echo "8. Route to Machine 2:"
ip route get $MACHINE2_IP

echo ""
echo "9. ARP Entry for Machine 2:"
arp -n | grep $MACHINE2_IP

echo ""
echo "10. Test from localhost:"
timeout 2 bash -c "echo > /dev/tcp/127.0.0.1/$TEST_PORT" && echo "✓ Localhost works" || echo "✗ Localhost fails"

echo ""
echo "11. Test from physical IP:"
timeout 2 bash -c "echo > /dev/tcp/192.168.0.193/$TEST_PORT" && echo "✓ Physical IP works" || echo "✗ Physical IP fails"

echo ""
echo "12. Docker proxy processes:"
ps aux | grep docker-proxy | grep $TEST_PORT

echo ""
echo "=== End Diagnostic ==="