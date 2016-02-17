# Copyright (c) 2016 Cisco and/or its affiliates.
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

"""IPv4 setup library"""

from socket import inet_ntoa
from struct import pack
from abc import ABCMeta, abstractmethod
from robot.api.deco import keyword

import resources.libraries.python.ssh as ssh
from resources.libraries.python.Routing import Routing
from resources.libraries.python.InterfaceUtil import InterfaceUtil
from resources.libraries.python.topology import NodeType, Topology
from resources.libraries.python.VatExecutor import VatExecutor


class IPv4Node(object):
    """Abstract class of a node in a topology."""
    __metaclass__ = ABCMeta

    def __init__(self, node_info):
        self.node_info = node_info

    @staticmethod
    def _get_netmask(prefix_length):
        bits = 0xffffffff ^ (1 << 32 - prefix_length) - 1
        return inet_ntoa(pack('>I', bits))

    @abstractmethod
    def set_ip(self, interface, address, prefix_length):
        """Configure IPv4 address on interface

        :param interface: interface name
        :param address:
        :param prefix_length:
        :type interface: str
        :type address: str
        :type prefix_length: int
        :return: nothing
        """
        pass

    @abstractmethod
    def set_route(self, network, prefix_length, gateway, interface):
        """Configure IPv4 route

        :param network: network IPv4 address
        :param prefix_length: mask length
        :param gateway: IPv4 address of the gateway
        :param interface: interface name
        :type network: str
        :type prefix_length: int
        :type gateway: str
        :type interface: str
        :return: nothing
        """
        pass

    @abstractmethod
    def unset_route(self, network, prefix_length, gateway, interface):
        """Remove specified IPv4 route

        :param network: network IPv4 address
        :param prefix_length: mask length
        :param gateway: IPv4 address of the gateway
        :param interface: interface name
        :type network: str
        :type prefix_length: int
        :type gateway: str
        :type interface: str
        :return: nothing
        """
        pass

    @abstractmethod
    def flush_ip_addresses(self, interface):
        """Flush all IPv4 addresses from specified interface

        :param interface: interface name
        :type interface: str
        :return: nothing
        """
        pass

    @abstractmethod
    def ping(self, destination_address, source_interface):
        """Send an ICMP request to destination node

        :param destination_address: address to send the ICMP request
        :param source_interface:
        :type destination_address: str
        :type source_interface: str
        :return: nothing
        """
        pass


class Tg(IPv4Node):
    """Traffic generator node"""
    def __init__(self, node_info):
        super(Tg, self).__init__(node_info)

    def _execute(self, cmd):
        return ssh.exec_cmd_no_error(self.node_info, cmd)

    def _sudo_execute(self, cmd):
        return ssh.exec_cmd_no_error(self.node_info, cmd, sudo=True)

    def set_ip(self, interface, address, prefix_length):
        cmd = 'ip -4 addr flush dev {}'.format(interface)
        self._sudo_execute(cmd)
        cmd = 'ip addr add {}/{} dev {}'.format(address, prefix_length,
                                                interface)
        self._sudo_execute(cmd)

    def set_route(self, network, prefix_length, gateway, interface):
        netmask = self._get_netmask(prefix_length)
        cmd = 'route add -net {} netmask {} gw {}'.\
            format(network, netmask, gateway)
        self._sudo_execute(cmd)

    def unset_route(self, network, prefix_length, gateway, interface):
        self._sudo_execute('ip route delete {}/{}'.
                           format(network, prefix_length))

    def arp_ping(self, destination_address, source_interface):
        self._sudo_execute('arping -c 1 -I {} {}'.format(source_interface,
                                                         destination_address))

    def ping(self, destination_address, source_interface):
        self._execute('ping -c 1 -w 5 -I {} {}'.format(source_interface,
                                                       destination_address))

    def flush_ip_addresses(self, interface):
        self._sudo_execute('ip addr flush dev {}'.format(interface))


class Dut(IPv4Node):
    """Device under test"""
    def __init__(self, node_info):
        super(Dut, self).__init__(node_info)

    def get_sw_if_index(self, interface):
        """Get sw_if_index of specified interface from current node

        :param interface: interface name
        :type interface: str
        :return: sw_if_index of 'int' type
        """
        return Topology().get_interface_sw_index(self.node_info, interface)

    def exec_vat(self, script, **args):
        """Wrapper for VAT executor.

        :param script: script to execute
        :param args: parameters to the script
        :type script: str
        :type args: dict
        :return: nothing
        """
        # TODO: check return value
        VatExecutor.cmd_from_template(self.node_info, script, **args)

    def set_arp(self, interface, ip_address, mac_address):
        """Set entry in ARP cache.

        :param interface: Interface name.
        :param ip_address: IP address.
        :param mac_address: MAC address.
        :type interface: str
        :type ip_address: str
        :type mac_address: str
        """
        self.exec_vat('add_ip_neighbor.vat',
                      sw_if_index=self.get_sw_if_index(interface),
                      ip_address=ip_address, mac_address=mac_address)

    def set_ip(self, interface, address, prefix_length):
        self.exec_vat('add_ip_address.vat',
                      sw_if_index=self.get_sw_if_index(interface),
                      address=address, prefix_length=prefix_length)

    def set_route(self, network, prefix_length, gateway, interface):
        Routing.vpp_route_add(self.node_info,
                      network=network, prefix_len=prefix_length,
                      gateway=gateway, interface=interface)

    def unset_route(self, network, prefix_length, gateway, interface):
        self.exec_vat('del_route.vat', network=network,
                      prefix_length=prefix_length, gateway=gateway,
                      sw_if_index=self.get_sw_if_index(interface))

    def arp_ping(self, destination_address, source_interface):
        pass

    def flush_ip_addresses(self, interface):
        self.exec_vat('flush_ip_addresses.vat',
                      sw_if_index=self.get_sw_if_index(interface))

    def ping(self, destination_address, source_interface):
        pass


def get_node(node_info):
    """Creates a class instance derived from Node based on type.

    :param node_info: dictionary containing information on nodes in topology
    :return: Class instance that is derived from Node
    """
    if node_info['type'] == NodeType.TG:
        return Tg(node_info)
    elif node_info['type'] == NodeType.DUT:
        return Dut(node_info)
    else:
        raise NotImplementedError('Node type "{}" unsupported!'.
                                  format(node_info['type']))


class IPv4Setup(object):
    """IPv4 setup in topology."""

    @staticmethod
    def vpp_nodes_setup_ipv4_addresses(nodes, nodes_addr):
        """Setup IPv4 addresses on all VPP nodes in topology.

           :param nodes: Nodes of the test topology.
           :param nodes_addr: Available nodes IPv4 adresses.
           :type nodes: dict
           :type nodes_addr: dict
        """
        for net in nodes_addr.values():
            for port in net['ports'].values():
                host = port.get('node')
                if host is None:
                    continue
                topo = Topology()
                node = topo.get_node_by_hostname(nodes, host)
                if node is None:
                    continue
                if node['type'] != NodeType.DUT:
                    continue
                get_node(node).set_ip(port['if'], port['addr'], net['prefix'])
                InterfaceUtil.set_interface_state(node, port['if'], 'up')

    @staticmethod
    @keyword('Get IPv4 address of node "${node}" interface "${port}" '
             'from "${nodes_addr}"')
    def get_ip_addr(node, interface, nodes_addr):
        """Return IPv4 address of the node port.
        :param node: Node in the topology.
        :param interface: Interface name of the node.
        :param nodes_addr: Nodes IPv4 adresses.
        :type node: dict
        :type interface: str
        :type nodes_addr: dict
        :return: IPv4 address string
        """
        for net in nodes_addr.values():
            for port in net['ports'].values():
                host = port.get('node')
                dev = port.get('if')
                if host == node['host'] and dev == interface:
                    ip = port.get('addr')
                    if ip is not None:
                        return ip
                    else:
                        raise Exception(
                            'Node {n} port {p} IPv4 address is not set'.format(
                                n=node['host'], p=interface))

        raise Exception('Node {n} port {p} IPv4 address not found.'.format(
            n=node['host'], p=interface))

    @staticmethod
    def setup_arp_on_all_duts(nodes_info, nodes_addr):
        """For all DUT nodes extract MAC and IP addresses of adjacent
        interfaces from topology and use them to setup ARP entries.

        :param nodes_info: Dictionary containing information on all nodes
        in topology.
        :param nodes_addr: Nodes IPv4 adresses.
        :type nodes_info: dict
        :type nodes_addr: dict
        """
        for node in nodes_info.values():
            if node['type'] == NodeType.TG:
                continue
            for interface, interface_data in node['interfaces'].iteritems():
                if interface == 'mgmt':
                    continue
                interface_name = interface_data['name']
                adj_node, adj_int = Topology.\
                    get_adjacent_node_and_interface(nodes_info, node,
                                                    interface_name)
                ip_address = IPv4Setup.get_ip_addr(adj_node, adj_int['name'],
                                                   nodes_addr)
                mac_address = adj_int['mac_address']
                get_node(node).set_arp(interface_name, ip_address, mac_address)