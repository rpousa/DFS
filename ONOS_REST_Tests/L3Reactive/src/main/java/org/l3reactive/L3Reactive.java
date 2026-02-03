package org.l3reactive;

import org.osgi.service.component.annotations.Component;
import org.osgi.service.component.annotations.Reference;
import org.osgi.service.component.annotations.ReferenceCardinality;
import org.osgi.service.component.annotations.Activate;
import org.osgi.service.component.annotations.Deactivate;

import org.onlab.packet.Ethernet;
import org.onlab.packet.MacAddress;
import org.onlab.packet.IPv4;
import org.onlab.packet.IPv6;
import org.onlab.packet.Ip4Address;
import org.onlab.packet.Ip6Address;
import org.onlab.packet.IpAddress;
import org.onlab.packet.IpPrefix;
import org.onlab.packet.UDP;

import org.onosproject.core.ApplicationId;
import org.onosproject.core.CoreService;

import org.onosproject.net.device.DeviceService;
import org.onosproject.net.device.DeviceListener;
import org.onosproject.net.device.DeviceEvent;

import org.onosproject.net.driver.DriverService;
import org.onosproject.net.driver.DriverHandler;
import org.onosproject.net.behaviour.QueueId;
import org.onosproject.net.behaviour.QueueDescription;
import org.onosproject.net.behaviour.DefaultQueueDescription;
import org.onosproject.net.behaviour.QueueConfigBehaviour;
import org.onlab.util.Bandwidth;
import java.util.HashMap;
import java.util.Map;

import org.onosproject.net.Device;
import org.onosproject.net.DeviceId;
import org.onosproject.net.Port;
import org.onosproject.net.PortNumber;
import org.onosproject.net.ConnectPoint;

import org.onosproject.net.Host;
import org.onosproject.net.host.HostService;
import org.onosproject.net.HostId;
import org.onosproject.net.HostLocation;

import org.onosproject.net.topology.PathService;
import org.onosproject.net.Path;
import org.onosproject.net.Link;

import org.onosproject.net.packet.PacketProcessor;
import org.onosproject.net.packet.PacketService;
import org.onosproject.net.packet.InboundPacket;
import org.onosproject.net.packet.PacketContext;
import org.onosproject.net.packet.PacketPriority;

import org.onosproject.net.flow.FlowRuleService;
import org.onosproject.net.flow.FlowRule;
import org.onosproject.net.flow.DefaultFlowRule;
import org.onosproject.net.flow.DefaultTrafficSelector;
import org.onosproject.net.flow.DefaultTrafficTreatment;
import org.onosproject.net.flow.TrafficSelector;
import org.onosproject.net.flow.TrafficTreatment;

import org.onosproject.net.intent.IntentService;
import org.onosproject.net.intent.Intent;
import org.onosproject.net.intent.Key;
import org.onosproject.net.intent.HostToHostIntent;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.Set;

/**
 * L3Reactive
 *
 * - Install HostToHostIntent for discovered IPv4/IPv6 hosts
 * - Install high-priority flows (per src/dst/proto) on ingress switch
 * - Install special high-priority GTP-U (UDP dst 2152) flows that set queue
 */
@Component(immediate = true)
public class L3Reactive {

    private final String CONTROLLER_IP = "192.168.71.168";
    private final Logger log = LoggerFactory.getLogger(getClass());

    private static final int INTENT_PRIORITY = 400; // Intent Priority lower than flows
    private static final int NON_IP_FLOW_PRIORITY = 500; // Intent Priority lower than flows
    private static final int FLOW_PRIORITY = 5000; // Flow Priority over that of intents
    private static final int FLOW_TIMEOUT_SECONDS = 0; // Permanent Flows

    @Reference(cardinality = ReferenceCardinality.MANDATORY)
    protected CoreService coreService;

    @Reference(cardinality = ReferenceCardinality.MANDATORY)
    protected PacketService packetService;

    @Reference(cardinality = ReferenceCardinality.MANDATORY)
    protected FlowRuleService flowRuleService;

    @Reference(cardinality = ReferenceCardinality.MANDATORY)
    protected HostService hostService;

    @Reference(cardinality = ReferenceCardinality.MANDATORY)
    protected IntentService intentService;

    @Reference(cardinality = ReferenceCardinality.MANDATORY)
    protected PathService pathService;

    @Reference(cardinality = ReferenceCardinality.MANDATORY)
    protected DeviceService deviceService;

    @Reference(cardinality = ReferenceCardinality.MANDATORY)
    protected DriverService driverService;


    private ApplicationId appId;
    private final ReactiveProcessor processor = new ReactiveProcessor();
    private final InternalDeviceListener deviceListener = new InternalDeviceListener();

    // IPV6 and IPV4 for congruity sake
    @Activate
    protected void activate() {
        appId = coreService.registerApplication("org.l3reactive.L3Reactive");

        TrafficSelector selector = DefaultTrafficSelector.builder()
                .matchEthType(Ethernet.TYPE_IPV4) 
                .build();
        packetService.requestPackets(selector, PacketPriority.REACTIVE, appId);

        TrafficSelector selector6 = DefaultTrafficSelector.builder()
                .matchEthType(Ethernet.TYPE_IPV6) 
                .build();
        packetService.requestPackets(selector6, PacketPriority.REACTIVE, appId);

        packetService.addProcessor(processor, PacketProcessor.director(2));
        
        deviceService.addListener(deviceListener);

        for (Device device : deviceService.getDevices()) {
            processor.installControllerReachabilityFlow(device.id());
            DriverHandler handler = driverService.createHandler(device.id()); //
            if (handler == null){
                log.warn("No driver handler for device {}", device.id());
                continue;
            }else{
                if (handler.hasBehaviour(QueueConfigBehaviour.class)) {
                    QueueConfigBehaviour queueConfig = handler.behaviour(QueueConfigBehaviour.class);
                    QueueDescription queueDesc = DefaultQueueDescription.builder()
                            .queueId(QueueId.queueId("1"))
                            .build();

                    boolean added = queueConfig.addQueue(queueDesc);
                    if (!added) {
                        log.warn("Failed to add queue on device {}", device.id());
                        continue;
                    }
                    log.info("Configured queue on device {}", device.id());
                    
                }else{
                    log.warn("Device {} does not support QueueConfigBehaviour", device.id());
                }
            }
        }
        log.info("Started L3Reactive (appId={})", appId.id());
    }

    // Teardown IPV6 and IPV4 for congruity sake
    @Deactivate
    protected void deactivate() {
        packetService.removeProcessor(processor);
        deviceService.removeListener(deviceListener);

        TrafficSelector selector = DefaultTrafficSelector.builder()
                .matchEthType(Ethernet.TYPE_IPV4)
                .build();
        packetService.cancelPackets(selector, PacketPriority.REACTIVE, appId);

        TrafficSelector selector6 = DefaultTrafficSelector.builder()
                .matchEthType(Ethernet.TYPE_IPV6)
                .build();
        packetService.cancelPackets(selector6, PacketPriority.REACTIVE, appId);

        log.info("Stopped L3Reactive");
    }

    private class InternalDeviceListener implements DeviceListener {
        @Override
        public void event(DeviceEvent event) {
            if (event.type() == DeviceEvent.Type.DEVICE_ADDED) {
                DeviceId deviceId = event.subject().id();
                log.info("Device connected: {}", deviceId);
                processor.installControllerReachabilityFlow(deviceId);
            }
        }
    }
    private class ReactiveProcessor implements PacketProcessor {

        @Override
        public void process(PacketContext context) {
            if (context.isHandled()) {return;}

            InboundPacket inPkt = context.inPacket();
            Ethernet eth = inPkt.parsed();
            if (eth == null) {return;}

            MacAddress srcMac = eth.getSourceMAC();
            MacAddress dstMac = eth.getDestinationMAC();
            ConnectPoint inCp = inPkt.receivedFrom(); 
            DeviceId ingressDevice = inCp.deviceId(); 
            PortNumber inPort = inCp.port();

            // IPv4 
            if (eth.getEtherType() == Ethernet.TYPE_IPV4) {
                IPv4 ipv4 = (IPv4) eth.getPayload();
                if (ipv4 == null) return;

                Ip4Address srcIp = Ip4Address.valueOf(ipv4.getSourceAddress());
                Ip4Address dstIp = Ip4Address.valueOf(ipv4.getDestinationAddress());
                byte proto = ipv4.getProtocol();

                log.debug("IPv4 packet-in: {} -> {} proto={} on {}", srcIp, dstIp, proto, ingressDevice);

                //submitHostIntentForIp(srcIp, dstIp);

                installL3FlowIPv4(ingressDevice, srcIp, dstIp, proto, inPort, dstMac);
                                     
                // if (proto == IPv4.PROTOCOL_UDP) {
                //     UDP udp = (UDP) ipv4.getPayload();
                //     if (udp != null && udp.getDestinationPort() == 2152) {
                //         installGtpuQueueFlowIPv4(ingressDevice, srcIp, dstIp, inPort, /*queueId=*/1, dstMac);
                //     }    
                // }
                
                Host dstHost = findHostByIp(IpAddress.valueOf(dstIp.toString()));
                if (dstHost != null && dstHost.location().deviceId().equals(ingressDevice)) {
                    context.treatmentBuilder().setOutput(dstHost.location().port());
                    context.send();
                }
                return;
            }

        }
        
        protected void installControllerReachabilityFlow(DeviceId deviceId) {
            
            Host controllerHost = hostService.getHostsByIp(IpAddress.valueOf(CONTROLLER_IP)).stream().findFirst().orElse(null);

            if (controllerHost == null) {
                log.warn("Controller host {} not found in topology", CONTROLLER_IP);
                return;
            }

            // Find which port on this device connects to the controller
            HostLocation controllerLocation = controllerHost.location();
            if (!controllerLocation.deviceId().equals(deviceId)) {
                log.debug("Controller is reachable via another device {}", controllerLocation.deviceId());
                return;
            }

            PortNumber controllerPort = controllerLocation.port();
            PortNumber onosPort = null;
            for (Port p : deviceService.getPorts(deviceId)) {
                if (p.annotations().value("portName").equals("sw1-onos")) {
                    onosPort = p.number();
                }
            }
            if (onosPort == null) {
                log.warn("ONOS port not found on device {}", deviceId);
                return;
            }
            // Build selector: traffic destined to controller IP
            TrafficSelector sel = DefaultTrafficSelector.builder()
                    .matchEthType(Ethernet.TYPE_IPV4)
                    .matchIPDst(IpPrefix.valueOf(Ip4Address.valueOf(CONTROLLER_IP), 32))
                    .build();

            // Forward to the dynamically discovered port
            TrafficTreatment treat = DefaultTrafficTreatment.builder()
            //      .setOutput(controllerPort)
                    .setOutput(onosPort)
                    .build();

            FlowRule fr = DefaultFlowRule.builder()
                    .forDevice(deviceId)
                    .withSelector(sel)
                    .withTreatment(treat)
                    .fromApp(appId)
                    .withPriority(10000)
                    .makePermanent()
                    .build();

            flowRuleService.applyFlowRules(fr);
            log.info("Installed controller reachability flow on {} via port {}", deviceId, controllerPort);

        }

        private void submitHostIntentForIp(IpAddress src, IpAddress dst) {
            try {
                Set<Host> srcHosts = hostService.getHostsByIp(src);
                Set<Host> dstHosts = hostService.getHostsByIp(dst);
                if (dstHosts == null || dstHosts.isEmpty()) {
                    log.debug("No destination host found for IP {}", dst);
                    return;
                }
                if (srcHosts == null || srcHosts.isEmpty()) {
                    log.debug("No source host found for IP {}, skipping intent (we still install flows)", src);
                    return;
                }

                HostId h1 = srcHosts.iterator().next().id();
                HostId h2 = dstHosts.iterator().next().id();

                // Build HostToHostIntent and submit
                HostToHostIntent intent = HostToHostIntent.builder()
                        .appId(appId)
                        .one(h1)
                        .two(h2)
                        .priority(INTENT_PRIORITY)
                        .build();

                intentService.submit(intent);
                log.debug("Submitted HostToHostIntent {} -> {}", h1, h2);
            } catch (Exception e) {
                log.warn("Failed to submit intent: {}", e.toString());
            }
        }

        private Host findHostByIp(IpAddress ip) {
            Set<Host> hosts = hostService.getHostsByIp(ip);
            return (hosts == null || hosts.isEmpty()) ? null : hosts.iterator().next();
        }

        // IPv4 flow installs
        private void installL3FlowIPv4(DeviceId device, Ip4Address src, Ip4Address dst, byte proto, PortNumber inPort, MacAddress dstMac) {
            TrafficSelector sel = DefaultTrafficSelector.builder()
                    .matchEthType(Ethernet.TYPE_IPV4)
                    .matchIPSrc(IpPrefix.valueOf(src, 32))
                    .matchIPDst(IpPrefix.valueOf(dst, 32))
                    .matchIPProtocol(proto)
                    .matchInPort(inPort)
                    .build();

            PortNumber port = getOutPort(device, dstMac);
            TrafficTreatment treat = DefaultTrafficTreatment.builder()
                    .setOutput(port) // safe default; you can change to next-hop after path resolution
                    .build();

            FlowRule.Builder fb = DefaultFlowRule.builder()
                    .forDevice(device)
                    .withSelector(sel)
                    .withTreatment(treat)
                    .fromApp(appId)
                    .withPriority(FLOW_PRIORITY);

            if (FLOW_TIMEOUT_SECONDS > 0) {
                fb.makeTemporary(FLOW_TIMEOUT_SECONDS);
            } else {
                fb.makePermanent();
            }

            FlowRule fr = fb.build();
            flowRuleService.applyFlowRules(fr);

            log.info("Installed IPv4 L3 flow on {}: {} -> {} proto={} (inPort={})", device, src, dst, proto, inPort);
        }

        private void installFlowByMac(DeviceId device, MacAddress src, MacAddress dst, PortNumber inPort) {
            TrafficSelector sel = DefaultTrafficSelector.builder()
                    .matchEthSrc(src)
                    .matchEthDst(dst)
                    .matchInPort(inPort)
                    .build();

            PortNumber port = getOutPort(device, dst);
            TrafficTreatment treat = DefaultTrafficTreatment.builder()
                    .setOutput(port) // safe default; you can change to next-hop after path resolution
                    .build();

            FlowRule.Builder fb = DefaultFlowRule.builder()
                    .forDevice(device)
                    .withSelector(sel)
                    .withTreatment(treat)
                    .fromApp(appId)
                    .withPriority(FLOW_PRIORITY - 1000);

            if (FLOW_TIMEOUT_SECONDS > 0) {
                fb.makeTemporary(FLOW_TIMEOUT_SECONDS);
            } else {
                fb.makePermanent();
            }

            FlowRule fr = fb.build();
            flowRuleService.applyFlowRules(fr);

            log.info("Installed Eth flow on {}: {} -> {}  (inPort={})", device, src, dst, inPort);
        }

        private PortNumber getOutPort(DeviceId srcDevice, MacAddress dstMac) {
            Host dstHost = findHostByMac(dstMac);
            
            if (dstHost == null) {
                log.debug("Unknown destination MAC {}, flooding", dstMac);
                return PortNumber.FLOOD;
            }
            
            DeviceId dstDevice = dstHost.location().deviceId();
            PortNumber dstPort = dstHost.location().port();
            
            if (dstDevice.equals(srcDevice)) {
                log.debug("Destination on same device, direct output to port {}", dstPort);
                return dstPort;
            }
            
            Path path = getPath(srcDevice, dstDevice);
            if (path == null || path.links().isEmpty()) {
                log.warn("No path found from {} to {}, flooding", srcDevice, dstDevice);
                return PortNumber.FLOOD;
            }
            
            PortNumber nextHopPort = nextHopPort(srcDevice, path);
            if (nextHopPort == null) {
                log.warn("Cannot determine next hop port, flooding");
                return PortNumber.FLOOD;
            }
            
            return nextHopPort;
        }
        
        private Host findHostByMac(MacAddress mac) {
            for (Host h : hostService.getHosts()) {
                if (h.mac().equals(mac)) {
                    return h;
                }
            }
            return null;
        }
        private Path getPath(DeviceId src, DeviceId dst) {
            Set<Path> paths = pathService.getPaths(src, dst);
            if (paths == null || paths.isEmpty()) {
                return null;
            }
            return paths.iterator().next();
        }

        private PortNumber nextHopPort(DeviceId device, Path path) {
        for (Link l : path.links()) {
            if (l.src().deviceId().equals(device)) {
                return l.src().port();
            }
        }
        return null;
        }

        // GTP-U queueing flow for IPv4
        private void installGtpuQueueFlowIPv4(DeviceId device, Ip4Address src, Ip4Address dst,
                                              PortNumber inPort, int queueId, MacAddress dstMac) {
            TrafficSelector.Builder sb = DefaultTrafficSelector.builder()
                    .matchEthType(Ethernet.TYPE_IPV4)
                    .matchIPSrc(IpPrefix.valueOf(src, 32))
                    .matchIPDst(IpPrefix.valueOf(dst, 32))
                    .matchIPProtocol(IPv4.PROTOCOL_UDP)
                    .matchInPort(inPort);
            // Note: UDP dst port match APIs vary with versions; ONOS sometimes provides matchUdpDst
            // If supported in your ONOS API, add .matchUdpDst(TpPort.tpPort(2152))
            TrafficSelector sel = sb.build();

            Host dstHost = hostService.getHost(HostId.hostId(dstMac));

            TrafficTreatment treat = DefaultTrafficTreatment.builder()
                    .setQueue(queueId)
                    .build();

            FlowRule fr = DefaultFlowRule.builder()
                    .forDevice(device)
                    .withSelector(sel)
                    .withTreatment(treat)
                    .fromApp(appId)
                    .withPriority(FLOW_PRIORITY)
                    .makePermanent()
                    .build();

            flowRuleService.applyFlowRules(fr);
            log.info("Installed GTP-U queue flow (IPv4) on {}: {} -> {} queue={}", device, src, dst, queueId);
        }

        // GTP-U queueing flow for IPv6
        private void installGtpuQueueFlowIPv6(DeviceId device, Ip6Address src, Ip6Address dst,
                                              PortNumber inPort, int queueId) {
            TrafficSelector sel = DefaultTrafficSelector.builder()
                    .matchEthType(Ethernet.TYPE_IPV6)
                    .matchIPSrc(IpPrefix.valueOf(src, 128))
                    .matchIPDst(IpPrefix.valueOf(dst, 128))
                    .matchIPProtocol(IPv6.PROTOCOL_UDP)
                    .matchInPort(inPort)
                    .build();

            TrafficTreatment treat = DefaultTrafficTreatment.builder()
                    .setQueue(queueId)
                    .build();

            FlowRule fr = DefaultFlowRule.builder()
                    .forDevice(device)
                    .withSelector(sel)
                    .withTreatment(treat)
                    .fromApp(appId)
                    .withPriority(FLOW_PRIORITY)
                    .makePermanent()
                    .build();

            flowRuleService.applyFlowRules(fr);
            log.info("Installed GTP-U queue flow (IPv6) on {}: {} -> {} queue={}", device, src, dst, queueId);
        }
    }
}
