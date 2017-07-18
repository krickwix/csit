# Copyright (c) 2017 Cisco and/or its affiliates.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at:
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

*** Settings ***
| Resource | resources/libraries/robot/performance/performance_setup.robot
| Library | resources.libraries.python.QemuUtils
| ...
| Force Tags | 3_NODE_SINGLE_LINK_TOPO | PERFTEST | HW_ENV | NDRPDRDISC
| ... | NIC_Intel-X520-DA2 | ETH | IP4FWD | BASE | VHOST | VM | VHOST_1024
| ... | CFS_OPT
| ...
| Suite Setup | Set up 3-node performance topology with DUT's NIC model
| ... | L3 | Intel-X520-DA2
| Suite Teardown | Tear down 3-node performance topology
| ...
| Test Setup | Set up performance test
| Test Teardown | Tear down performance test with vhost and VM with dpdk-testpmd
| ... | ${min_rate}pps | ${framesize} | ${traffic_profile}
| ... | dut1_node=${dut1} | dut1_vm_refs=${dut1_vm_refs}
| ... | dut2_node=${dut2} | dut2_vm_refs=${dut2_vm_refs}
| ...
| Documentation | *RFC2544: Packet throughput L2BD test cases with vhost*
| ...
| ... | *[Top] Network Topologies:* TG-DUT1-DUT2-TG 3-node circular topology
| ... | with single links between nodes.
| ... | *[Enc] Packet Encapsulations:* Eth-IPv4 for IPv4 routing.
| ... | *[Cfg] DUT configuration:* DUT1 and DUT2 are configured with IPv4
| ... | routing and two static IPv4 /24 route entries. Qemu Guest is connected
| ... | to VPP via vhost-user interfaces. Guest is running DPDK testpmd
| ... | interconnecting vhost-user interfaces using 5 cores pinned to cpus 5-9
| ... | and 2048M memory. Testpmd is using socket-mem=1024M (512x2M hugepages),
| ... | 5 cores (1 main core and 4 cores dedicated for io), forwarding mode is
| ... | set to mac, rxd/txd=1024, burst=64. Scheduler policy is set to SCHED_RR
| ... | with priority 1 for all Qemu CPUs. DUT1, DUT2 are tested with 2p10GE
| ... | NIC X520 Niantic by Intel.
| ... | *[Ver] TG verification:* TG finds and reports throughput NDR (Non Drop
| ... | Rate) with zero packet loss tolerance or throughput PDR (Partial Drop
| ... | Rate) with non-zero packet loss tolerance (LT) expressed in percentage
| ... | of packets transmitted. NDR and PDR are discovered for different
| ... | Ethernet L2 frame sizes using either binary search or linear search
| ... | algorithms with configured starting rate and final step that determines
| ... | throughput measurement resolution. Test packets are generated by TG on
| ... | links to DUTs. TG traffic profile contains two L3 flow-groups
| ... | (flow-group per direction, 253 flows per flow-group) with all packets
| ... | containing Ethernet header, IPv4 header with IP protocol=61 and static
| ... | payload. MAC addresses are matching MAC addresses of the TG node
| ... | interfaces.
| ... | *[Ref] Applicable standard specifications:* RFC2544.

*** Variables ***
| ${avg_imix_framesize}= | ${357.833}
# X520-DA2 bandwidth limit
| ${s_limit} | ${10000000000}
# Socket names
| ${sock1}= | /tmp/sock-1-1
| ${sock2}= | /tmp/sock-1-2
# FIB tables
| ${fib_table_1}= | 100
| ${fib_table_2}= | 101
# Traffic profile:
| ${traffic_profile} | trex-sl-3n-ethip4-ip4src253

*** Keywords ***
| Discover NDR or PDR for IPv4 forwarding with VM
| | [Arguments] | ${wt} | ${rxq} | ${framesize} | ${min_rate} | ${search_type}
| | ...
| | Set Test Variable | ${use_tuned_cfs} | ${True}
| | Set Test Variable | ${framesize}
| | Set Test Variable | ${min_rate}
| | ${get_framesize}= | Set Variable If
| | ... | "${framesize}" == "IMIX_v4_1" | ${avg_imix_framesize}
| | ... |  ${framesize}
| | ${max_rate}= | Calculate pps | ${s_limit} | ${get_framesize}
| | ${binary_min}= | Set Variable | ${min_rate}
| | ${binary_max}= | Set Variable | ${max_rate}
| | ${threshold}= | Set Variable | ${min_rate}
| | ${dut1_vm_refs}= | Create Dictionary
| | ${dut2_vm_refs}= | Create Dictionary
| | Set Test Variable | ${dut1_vm_refs}
| | Set Test Variable | ${dut2_vm_refs}
| | Given Add '${wt}' worker threads and '${rxq}' rxqueues in 3-node single-link circular topology
| | And Add PCI devices to DUTs in 3-node single link topology
| | And Run Keyword If | ${get_framesize} < ${1522} | Add no multi seg to all DUTs
| | And Apply startup configuration on all VPP DUTs
| | When Initialize IPv4 forwarding with vhost in 3-node circular topology
| | ... | ${sock1} | ${sock2}
| | ${vm1}= | And Configure guest VM with dpdk-testpmd-mac connected via vhost-user
| | ... | ${dut1} | ${sock1} | ${sock2} | DUT1_VM1 | ${dut1_vif1_mac}
| | ... | ${dut1_vif2_mac}
| | Set To Dictionary | ${dut1_vm_refs} | DUT1_VM1 | ${vm1}
| | ${vm2}= | And Configure guest VM with dpdk-testpmd-mac connected via vhost-user
| | ... | ${dut2} | ${sock1} | ${sock2} | DUT2_VM1 | ${dut2_vif1_mac}
| | ... | ${dut2_vif2_mac}
| | Set To Dictionary | ${dut2_vm_refs} | DUT2_VM1 | ${vm2}
| | Run Keyword Unless | ${qemu_built} | Set Suite Variable | ${qemu_built}
| | ... | ${True}
| | Run Keyword If | '${search_type}' == 'NDR'
| | ... | Find NDR using binary search and pps
| | ... | ${framesize} | ${binary_min} | ${binary_max} | ${traffic_profile}
| | ... | ${min_rate} | ${max_rate} | ${threshold}
| | ... | ELSE IF | '${search_type}' == 'PDR'
| | ... | Find PDR using binary search and pps
| | ... | ${framesize} | ${binary_min} | ${binary_max} | ${traffic_profile}
| | ... | ${min_rate} | ${max_rate} | ${threshold}
| | ... | ${perf_pdr_loss_acceptance} | ${perf_pdr_loss_acceptance_type}

*** Test Cases ***
| tc01-64B-1t1c-ethip4-ip4base-eth-2vhostvr1024-1vm-cfsrr1-ndrdisc
| | [Documentation]
| | ... | [Cfg] DUT runs L2BD switching config with 1 thread, 1 phy core,\
| | ... | 1 receive queue per NIC port.
| | ... | [Ver] Find NDR for 64 Byte frames using binary search start at 10GE\
| | ... | linerate, step 10kpps.
| | ...
| | [Tags] | 64B | 1T1C | STHREAD | NDRDISC
| | ...
| | [Template] | Discover NDR or PDR for IPv4 forwarding with VM
| | wt=1 | rxq=1 | framesize=${64} | min_rate=${10000} | search_type=NDR

| tc02-64B-1t1c-ethip4-ip4base-eth-2vhostvr1024-1vm-cfsrr1-pdrdisc
| | [Documentation]
| | ... | [Cfg] DUT runs L2BD switching config with 1 thread, 1 phy core,\
| | ... | 1 receive queue per NIC port.
| | ... | [Ver] Find PDR for 64 Byte frames using binary search start at 10GE\
| | ... | linerate, step 10kpps, LT=0.5%.
| | ...
| | [Tags] | 64B | 1T1C | STHREAD | PDRDISC | SKIP_PATCH
| | ...
| | [Template] | Discover NDR or PDR for IPv4 forwarding with VM
| | wt=1 | rxq=1 | framesize=${64} | min_rate=${10000} | search_type=PDR

| tc03-1518B-1t1c-etc-l2bdbasemaclrn-eth-2vhostvr1024-1vm-cfsrr1-ndrdisc
| | [Documentation]
| | ... | [Cfg] DUT runs L2BD switching config with 1 thread, 1 phy core,\
| | ... | 1 receive queue per NIC port.
| | ... | [Ver] Find NDR for 1518 Byte frames using binary search start at 10GE\
| | ... | linerate, step 10kpps.
| | ...
| | [Tags] | 1518B | 1T1C | STHREAD | NDRDISC
| | ...
| | [Template] | Discover NDR or PDR for IPv4 forwarding with VM
| | wt=1 | rxq=1 | framesize=${1518} | min_rate=${10000} | search_type=NDR

| tc04-1518B-1t1c-ethip4-ip4base-eth-2vhostvr1024-1vm-cfsrr1-pdrdisc
| | [Documentation]
| | ... | [Cfg] DUT runs L2BD switching config with 1 thread, 1 phy core,\
| | ... | 1 receive queue per NIC port.
| | ... | [Ver] Find PDR for 1518 Byte frames using binary search start at 10GE\
| | ... | linerate, step 10kpps, LT=0.5%.
| | ...
| | [Tags] | 1518B | 1T1C | STHREAD | PDRDISC | SKIP_PATCH
| | ...
| | [Template] | Discover NDR or PDR for IPv4 forwarding with VM
| | wt=1 | rxq=1 | framesize=${1518} | min_rate=${10000} | search_type=PDR

| tc05-IMIX-1t1c-ethip4-ip4base-eth-2vhostvr1024-1vm-cfsrr1-ndrdisc
| | [Documentation]
| | ... | [Cfg] DUT runs L2BD switching config with 1 thread, 1 phy core,\
| | ... | 1 receive queue per NIC port.
| | ... | [Ver] Find NDR for IMIX_v4_1 framesize using binary search start at\
| | ... | 10GE linerate, step 10kpps.
| | ... | IMIX_v4_1 = (28x64B; 16x570B; 4x1518B)
| | ...
| | [Tags] | IMIX | 1T1C | STHREAD | NDRDISC
| | ...
| | [Template] | Discover NDR or PDR for IPv4 forwarding with VM
| | wt=1 | rxq=1 | framesize=IMIX_v4_1 | min_rate=${10000} | search_type=NDR

| tc06-IMIX-1t1c-ethip4-ip4base-eth-2vhostvr1024-1vm-cfsrr1-pdrdisc
| | [Documentation]
| | ... | [Cfg] DUT runs L2BD switching config with 1 thread, 1 phy core,\
| | ... | 1 receive queue per NIC port.
| | ... | [Ver] Find PDR for IMIX_v4_1 framesize using binary search start at\
| | ... | 10GE linerate, step 10kpps, LT=0.5%.
| | ... | IMIX_v4_1 = (28x64B; 16x570B; 4x1518B)
| | ...
| | [Tags] | IMIX | 1T1C | STHREAD | PDRDISC | SKIP_PATCH
| | ...
| | [Template] | Discover NDR or PDR for IPv4 forwarding with VM
| | wt=1 | rxq=1 | framesize=IMIX_v4_1 | min_rate=${10000} | search_type=PDR

| tc07-64B-2t2c-ethip4-ip4base-eth-2vhostvr1024-1vm-cfsrr1-ndrdisc
| | [Documentation]
| | ... | [Cfg] DUT runs L2BD switching config with 2 threads, 2 phy cores,\
| | ... | 1 receive queue per NIC port.
| | ... | [Ver] Find NDR for 64 Byte frames using binary search start at 10GE\
| | ... | linerate, step 10kpps.
| | ...
| | [Tags] | 64B | 2T2C | STHREAD | NDRDISC
| | ...
| | [Template] | Discover NDR or PDR for IPv4 forwarding with VM
| | wt=2 | rxq=1 | framesize=${64} | min_rate=${10000} | search_type=NDR

| tc08-64B-2t2c-ethip4-ip4base-eth-2vhostvr1024-1vm-cfsrr1-pdrdisc
| | [Documentation]
| | ... | [Cfg] DUT runs L2BD switching config with 2 threads, 2 phy cores,\
| | ... | 1 receive queue per NIC port.
| | ... | [Ver] Find PDR for 64 Byte frames using binary search start at 10GE\
| | ... | linerate, step 10kpps, LT=0.5%.
| | ...
| | [Tags] | 64B | 2T2C | STHREAD | PDRDISC | SKIP_PATCH
| | ...
| | [Template] | Discover NDR or PDR for IPv4 forwarding with VM
| | wt=2 | rxq=1 | framesize=${64} | min_rate=${10000} | search_type=PDR

| tc09-1518B-2t2c-ethip4-ip4base-eth-2vhostvr1024-1vm-cfsrr1-ndrdisc
| | [Documentation]
| | ... | [Cfg] DUT runs L2BD switching config with 2 threads, 2 phy cores,\
| | ... | 1 receive queue per NIC port.
| | ... | [Ver] Find NDR for 1518 Byte frames using binary search start at 10GE\
| | ... | linerate, step 10kpps.
| | ...
| | [Tags] | 1518B | 2T2C | STHREAD | NDRDISC | SKIP_PATCH
| | ...
| | [Template] | Discover NDR or PDR for IPv4 forwarding with VM
| | wt=2 | rxq=1 | framesize=${1518} | min_rate=${10000} | search_type=NDR

| tc10-1518B-2t2c-ethip4-ip4base-eth-2vhostvr1024-1vm-cfsrr1-pdrdisc
| | [Documentation]
| | ... | [Cfg] DUT runs L2BD switching config with 2 threads, 2 phy cores,\
| | ... | 1 receive queue per NIC port.
| | ... | [Ver] Find PDR for 1518 Byte frames using binary search start at 10GE\
| | ... | linerate, step 10kpps, LT=0.5%.
| | ...
| | [Tags] | 1518B | 2T2C | STHREAD | PDRDISC | SKIP_PATCH
| | ...
| | [Template] | Discover NDR or PDR for IPv4 forwarding with VM
| | wt=2 | rxq=1 | framesize=${1518} | min_rate=${10000} | search_type=PDR

| tc11-IMIX-2t2c-ethip4-ip4base-eth-2vhostvr1024-1vm-cfsrr1-ndrdisc
| | [Documentation]
| | ... | [Cfg] DUT runs L2BD switching config with 2 threads, 2 phy cores,\
| | ... | 1 receive queue per NIC port.
| | ... | [Ver] Find NDR for IMIX_v4_1 framesize using binary search start at\
| | ... | 10GE linerate, step 10kpps.
| | ... | IMIX_v4_1 = (28x64B; 16x570B; 4x1518B)
| | ...
| | [Tags] | IMIX | 2T2C | STHREAD | NDRDISC | SKIP_PATCH
| | ...
| | [Template] | Discover NDR or PDR for IPv4 forwarding with VM
| | wt=2 | rxq=1 | framesize=IMIX_v4_1 | min_rate=${10000} | search_type=NDR

| tc12-IMIX-2t2c-ethip4-ip4base-eth-2vhostvr1024-1vm-cfsrr1-pdrdisc
| | [Documentation]
| | ... | [Cfg] DUT runs L2BD switching config with 2 threads, 2 phy cores,\
| | ... | 1 receive queue per NIC port.
| | ... | [Ver] Find PDR for IMIX_v4_1 framesize using binary search start at\
| | ... | 10GE linerate, step 10kpps.
| | ... | IMIX_v4_1 = (28x64B; 16x570B; 4x1518B)
| | ...
| | [Tags] | IMIX | 2T2C | STHREAD | PDRDISC | SKIP_PATCH
| | ...
| | [Template] | Discover NDR or PDR for IPv4 forwarding with VM
| | wt=2 | rxq=1 | framesize=IMIX_v4_1 | min_rate=${10000} | search_type=PDR

| tc13-64B-4t4c-ethip4-ip4base-eth-2vhostvr1024-1vm-cfsrr1-ndrdisc
| | [Documentation]
| | ... | [Cfg] DUT runs L2BD switching config with 4 threads, 4 phy cores,\
| | ... | 2 receive queues per NIC port.
| | ... | [Ver] Find NDR for 64 Byte frames using binary search start at 10GE\
| | ... | linerate, step 10kpps.
| | ...
| | [Tags] | 64B | 4T4C | STHREAD | NDRDISC
| | ...
| | [Template] | Discover NDR or PDR for IPv4 forwarding with VM
| | wt=4 | rxq=2 | framesize=${64} | min_rate=${10000} | search_type=NDR

| tc14-64B-4t4c-ethip4-ip4base-eth-2vhostvr1024-1vm-cfsrr1-pdrdisc
| | [Documentation]
| | ... | [Cfg] DUT runs L2BD switching config with 4 threads, 4 phy cores,\
| | ... | 2 receive queues per NIC port.
| | ... | [Ver] Find PDR for 64 Byte frames using binary search start at 10GE\
| | ... | linerate, step 10kpps, LT=0.5%.
| | ...
| | [Tags] | 64B | 4T4C | STHREAD | PDRDISC | SKIP_PATCH
| | ...
| | [Template] | Discover NDR or PDR for IPv4 forwarding with VM
| | wt=4 | rxq=2 | framesize=${64} | min_rate=${10000} | search_type=PDR

| tc15-1518B-4t4c-ethip4-ip4base-eth-2vhostvr1024-1vm-cfsrr1-ndrdisc
| | [Documentation]
| | ... | [Cfg] DUT runs L2BD switching config with 4 threads, 4 phy cores,\
| | ... | 2 receive queues per NIC port.
| | ... | [Ver] Find NDR for 1518 Byte frames using binary search start at 10GE\
| | ... | linerate, step 10kpps.
| | ...
| | [Tags] | 1518B | 4T4C | STHREAD | NDRDISC | SKIP_PATCH
| | ...
| | [Template] | Discover NDR or PDR for IPv4 forwarding with VM
| | wt=4 | rxq=2 | framesize=${1518} | min_rate=${10000} | search_type=NDR

| tc16-1518B-4t4c-ethip4-ip4base-eth-2vhostvr1024-1vm-cfsrr1-pdrdisc
| | [Documentation]
| | ... | [Cfg] DUT runs L2BD switching config with 4 threads, 4 phy cores,\
| | ... | 2 receive queues per NIC port.
| | ... | [Ver] Find PDR for 1518 Byte frames using binary search start at 10GE\
| | ... | linerate, step 10kpps, LT=0.5%.
| | ...
| | [Tags] | 1518B | 4T4C | STHREAD | PDRDISC | SKIP_PATCH
| | ...
| | [Template] | Discover NDR or PDR for IPv4 forwarding with VM
| | wt=4 | rxq=2 | framesize=${1518} | min_rate=${10000} | search_type=PDR

| tc17-IMIX-4t4c-ethip4-ip4base-eth-2vhostvr1024-1vm-cfsrr1-ndrdisc
| | [Documentation]
| | ... | [Cfg] DUT runs L2BD switching config with 4 threads, 4 phy cores,\
| | ... | 2 receive queues per NIC port.
| | ... | [Ver] Find NDR for IMIX_v4_1 framesize using binary search start at\
| | ... | 10GE linerate, step 10kpps.
| | ... | IMIX_v4_1 = (28x64B; 16x570B; 4x1518B)
| | ...
| | [Tags] | IMIX | 4T4C | STHREAD | NDRDISC | SKIP_PATCH
| | ...
| | [Template] | Discover NDR or PDR for IPv4 forwarding with VM
| | wt=4 | rxq=2 | framesize=IMIX_v4_1 | min_rate=${10000} | search_type=NDR

| tc18-IMIX-4t4c-ethip4-ip4base-eth-2vhostvr1024-1vm-cfsrr1-pdrdisc
| | [Documentation]
| | ... | [Cfg] DUT runs L2BD switching config with 4 threads, 4 phy cores,\
| | ... | 2 receive queues per NIC port.
| | ... | [Ver] Find PDR for IMIX_v4_1 framesize using binary search start at\
| | ... | 10GE linerate, step 10kpps, LT=0.5%.
| | ... | IMIX_v4_1 = (28x64B; 16x570B; 4x1518B)
| | ...
| | [Tags] | IMIX | 4T4C | STHREAD | PDRDISC | SKIP_PATCH
| | ...
| | [Template] | Discover NDR or PDR for IPv4 forwarding with VM
| | wt=4 | rxq=2 | framesize=IMIX_v4_1 | min_rate=${10000} | search_type=PDR
