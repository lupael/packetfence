#!/usr/bin/perl

=head1 NAME

wmi_action

=head1 DESCRIPTION

unit test for wmi_action

=cut

use strict;
use warnings;
#
use lib '/usr/local/pf/lib';

BEGIN {
    #include test libs
    use lib qw(/usr/local/pf/t);
    #Module for overriding configuration paths
    use setup_test_config;
}

use Test::More tests => 7;

#This test will running last
use Test::NoWarnings;
use pf::config::builder::template_switches;
use pf::IniFiles;
use pf::mini_template;
use pf::constants::template_switch qw(@SUPPORTS);
my $supports = [ sort @SUPPORTS ];

my $builder = pf::config::builder::template_switches->new;

{

    my $conf = <<'CONF';
[PacketFence::Standard]
description=Standard Switch
radiusDisconnect=disconnect 
acceptVlan = <<EOT
Tunnel-Medium-Type  = 6
Tunnel-Type = 13
Tunnel-Private-Group-ID = $vlan
EOT
acceptRole = <<EOT
Filter-Id = $role
EOT
reject=<<EOT
Reply-Message = This node is not allowed to use this service
EOT
disconnect=<<EOT
Calling-Station-Id = $mac
NAS-IP-Address = $disconnectIp
EOT
CONF

    my ($error, $switch_templates) = build_from_conf($conf);
    is ($error, undef, "No Error found");
    is_deeply(
        $switch_templates,
        {
            'PacketFence::Standard' => {
                type => 'PacketFence::Standard',
                description => 'Standard Switch',
                radiusDisconnect => 'disconnect',
                acceptVlan => [
                    { name => 'Tunnel-Medium-Type', tmpl => pf::mini_template->new(6) },
                    { name => 'Tunnel-Type', tmpl => pf::mini_template->new(13) },
                    { name => 'Tunnel-Private-Group-ID', tmpl => pf::mini_template->new('$vlan') },
                ],
                acceptRole => [
                    { name => 'Filter-Id', tmpl => pf::mini_template->new('$role') }
                ],
                reject => [
                    { name => 'Reply-Message', tmpl => pf::mini_template->new('This node is not allowed to use this service')},
                ],
                disconnect => [
                    {name => 'Calling-Station-Id', tmpl => pf::mini_template->new('$mac') },
                    {name => 'NAS-IP-Address', tmpl => pf::mini_template->new('$disconnectIp') },
                ]
            },
            "::VENDORS" => {
                PacketFence => [
                    {
                        value    => 'PacketFence::Standard',
                        label    => 'Standard Switch',
                        supports => $supports,
                        is_template => 1,
                    },
                ]
            },
        },
        "Building the standard switch",
    );
}

{

    my $conf= <<'CONF';
[PacketFence::Standard]
description=Standard Switch
radiusDisconnect=disconnect 
coa=<<EOT
Calling-Station-Id = $mac
NAS-IP-Address = $disconnectIp
Cisco-AVPair = jisas=kksd
EOT
reject =<<EOT
Reply-Message = This node is not allowed to use this service
EOT
acceptUrl = Calling-Station-Id = $mac
CONF

    my ($error, $switch_templates) = build_from_conf($conf);
    is ($error, undef, "No Error found");
    is_deeply(
        $switch_templates,
        {
            'PacketFence::Standard' => {
                type => 'PacketFence::Standard',
                description => 'Standard Switch',
                radiusDisconnect => 'disconnect',
                coa => [
                    {name => 'Calling-Station-Id', tmpl => pf::mini_template->new('$mac') },
                    {name => 'NAS-IP-Address', tmpl => pf::mini_template->new('$disconnectIp') },
                    {name => 'Cisco-AVPair', tmpl => pf::mini_template->new('jisas=kksd'), vendor => 'Cisco' },
                ],
                reject => [
                    { name => 'Reply-Message', tmpl => pf::mini_template->new('This node is not allowed to use this service')},
                ],
                acceptUrl => [
                    {name => 'Calling-Station-Id', tmpl => pf::mini_template->new('$mac') },
                ],
            },
            "::VENDORS" => {
                PacketFence => [
                    {
                        value    => 'PacketFence::Standard',
                        label    => 'Standard Switch',
                        supports => [sort ('ExternalPortal', @$supports)],
                        is_template => 1,
                    },
                ]
            },
            "::SupportsExternalPortal" => {
                'PacketFence::Standard' => 1,
            },
        },
        "Building the standard switch",
    );
}

{

    my $conf= <<'CONF';
[PacketFence::Standard]
description=Standard Switch
radiusDisconnect=disconnect 
coa=<<EOT
Calling-Station-Id = $mac
NAS-IP-Address = ${disconnectIp
Cisco:Cisco-AVPair = jisas=kksd
EOT
reject=<<EOT
Reply-Message = This node is not allowed to use this service
EOT
disconnect= No Attribute
CONF

    my ($error, $switch_templates) = build_from_conf($conf);
    is_deeply(
        $error,
        [
            {
                'errors' => [
                    {
                        name      => 'unknown',
                        'text'    => 'No Attribute',
                        'message' => 'is not a valid radius attribute'
                    }
                ],
                'switch'  => 'PacketFence::Standard',
                'message' => 'Error building RADIUS scope disconnect'
            },
            {
                switch => 'PacketFence::Standard',
                message => 'Error building RADIUS scope coa',
                errors => [
                    {
                        text => 'NAS-IP-Address = ${disconnectIp',
                        name => 'NAS-IP-Address',
                        message => q(parse error: no matching }
${disconnectIp
~~~~~~~~~~~~~ ^ 
)
                    }
                ]
            }
        ],
        "Error found"
    );
    is_deeply(
        $switch_templates,
        {
            'PacketFence::Standard' => {
                type => 'PacketFence::Standard',
                description => 'Standard Switch',
                radiusDisconnect => 'disconnect',
                reject => [
                    { name => 'Reply-Message', tmpl => pf::mini_template->new('This node is not allowed to use this service')},
                ],
            },
            "::VENDORS" => {
                PacketFence => [
                    {
                        value    => 'PacketFence::Standard',
                        label    => 'Standard Switch',
                        supports => $supports,
                        is_template => 1,
                    },
                ]
            },
        },
        "Still built after an error was found",
    );
}


sub build_from_conf {
    my ($conf) = @_;
    my $ini = pf::IniFiles->new(-file => \$conf);
    return $builder->build($ini);
}

=head1 AUTHOR

Inverse inc. <info@inverse.ca>

=head1 COPYRIGHT

Copyright (C) 2005-2020 Inverse inc.

=head1 LICENSE

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301,
USA.

=cut

1;
