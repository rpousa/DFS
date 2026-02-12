.PHONY: help setup start stop restart status logs clean check test

# Default target
help:
	@echo "5G Network Emulation - Makefile Commands"
	@echo "========================================"
	@echo ""
	@echo "Available targets:"
	@echo "  make setup       - Initialize directory structure and check requirements"
	@echo "  make start       - Start the 5G network with proper sequencing"
	@echo "  make stop        - Stop the 5G network gracefully"
	@echo "  make restart     - Restart the network (stop + start)"
	@echo "  make status      - Show status of all services"
	@echo "  make logs        - Tail logs from all services"
	@echo "  make logs-core   - Tail logs from core network functions"
	@echo "  make logs-ran    - Tail logs from RAN components"
	@echo "  make clean       - Stop and remove everything (including volumes)"
	@echo "  make check       - Check system requirements and configuration"
	@echo "  make test        - Test UE connectivity"
	@echo ""
	@echo "Individual service logs:"
	@echo "  make logs-SERVICE  - View logs for specific service (e.g., make logs-amf)"
	@echo ""

# Initialize setup
setup:
	@echo "Running setup script..."
	@chmod +x setup.sh
	@./setup.sh

# Start the network
start:
	@echo "Starting 5G network..."
	@chmod +x start.sh
	@./start.sh

# Stop the network
stop:
	@echo "Stopping 5G network..."
	@chmod +x stop.sh
	@./stop.sh

# Stop and remove everything
clean:
	@echo "Cleaning up everything..."
	@chmod +x stop.sh
	@./stop.sh --all --force

# Restart the network
restart: stop
	@sleep 5
	@$(MAKE) start

# Show status
status:
	@echo "5G Network Status:"
	@echo "=================="
	@docker-compose ps

# View all logs
logs:
	@docker-compose logs -f

# View core network logs
logs-core:
	@docker-compose logs -f nrf amf smf pcf nssf udm udr ausf mysql

# View RAN logs
logs-ran:
	@docker-compose logs -f cucp cuup du_1 ue_1

# Individual service logs
logs-mysql:
	@docker logs -f mysql

logs-nrf:
	@docker logs -f nrf

logs-amf:
	@docker logs -f amf

logs-smf:
	@docker logs -f smf

logs-pcf:
	@docker logs -f pcf

logs-nssf:
	@docker logs -f nssf

logs-udm:
	@docker logs -f udm

logs-udr:
	@docker logs -f udr

logs-ausf:
	@docker logs -f ausf

logs-upf:
	@docker logs -f upf

logs-ext-dn:
	@docker logs -f ext_dn

logs-cucp:
	@docker logs -f cucp

logs-cuup:
	@docker logs -f cuup

logs-du-1:
	@docker logs -f du_1

logs-flexric:
	@docker logs -f flexric

logs-l2-proxy:
	@docker logs -f l2_proxy

logs-ue-1:
	@docker logs -f ue_1

# System checks
check:
	@echo "System Requirements Check:"
	@echo "=========================="
	@echo ""
	@echo "Docker version:"
	@docker --version
	@echo ""
	@echo "Docker Compose version:"
	@docker-compose --version || docker compose version
	@echo ""
	@echo "Available RAM:"
	@free -h | grep Mem
	@echo ""
	@echo "Available Disk Space:"
	@df -h . | tail -1
	@echo ""
	@echo "CPU Cores:"
	@nproc
	@echo ""
	@echo "Docker Networks:"
	@docker network ls | grep -E "NETWORK|5g|br-" || echo "No 5G networks found"
	@echo ""
	@echo "Docker Volumes:"
	@docker volume ls | grep -E "VOLUME|5g|mysql" || echo "No 5G volumes found"

# Test UE connectivity
test:
	@echo "Testing UE connectivity..."
	@echo "=========================="
	@echo ""
	@echo "Checking UE interface..."
	@docker exec ue_1 ip addr show 2>/dev/null | grep oaitun || echo "UE interface not found"
	@echo ""
	@echo "Testing ping to External DN (192.168.72.135)..."
	@docker exec ue_1 ping -c 4 -I oaitun_ue1 192.168.72.135 2>/dev/null || echo "Ping failed - UE may not be fully connected"

# Shell access to containers
shell-%:
	@docker exec -it $* bash

# Examples:
# make shell-amf    - Open shell in AMF container
# make shell-ue-1   - Open shell in UE container
