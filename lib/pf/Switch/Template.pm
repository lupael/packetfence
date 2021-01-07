package pf::Switch::Template;

=head1 NAME

pf::Switch::Template -

=head1 DESCRIPTION

pf::Switch::Template

=cut

use strict;
use warnings;
use base ('pf::Switch');
use Try::Tiny;
use pf::util::radius qw(perform_coa perform_disconnect);
use pf::Switch::constants;
use pf::constants;
use pf::constants::switch qw($DEFAULT_ACL_TEMPLATE);
use pf::radius::constants;
use pf::util qw(isenabled listify);
use List::MoreUtils qw(uniq);
use pf::constants::role qw($REJECT_ROLE $VOICE_ROLE);
use List::Util qw(pairs);
use pf::access_filter::radius;
use pf::accounting qw(node_accounting_dynauth_attr);
use pf::roles::custom;
use pf::mini_template;
use pf::locationlog;
use pf::SwitchSupports qw(
    WiredMacAuth
    WiredDot1x
    WirelessMacAuth
    WirelessDot1x
    RadiusVoip
    RoleBasedEnforcement
    ExternalPortal
);

use pf::constants::template_switch qw(
  $DISCONNECT_TYPE_COA
  $DISCONNECT_TYPE_DISCONNECT
  $DISCONNECT_TYPE_BOTH
  %WEBAUTH_TEMPLATE_TO_REQUEST_PARAM
);

use pf::config::template_switch qw(%TemplateSwitches);

our %DISCONNECT_DISPATCH = (
    $DISCONNECT_TYPE_COA => \&handleCoa,
    $DISCONNECT_TYPE_DISCONNECT => \&handleDisconnect,
    $DISCONNECT_TYPE_BOTH => \&handleCoaOrDisconnect,
);

our %LOOKUP = (
    last_accounting => \&lookupLastAccounting,
);

sub lookupLastAccounting {
    my ($self, $args) = @_;
    if (!exists $args->{mac}) {
        return undef;
    }

    my $mac = $args->{mac};
    if ($mac) {
        return node_accounting_dynauth_attr($mac);
    }

    return undef;
}

sub makeRadiusAttributesWithVSA {
    my ($self, $attrs_tmpl, $vars) = @_;
    my @vsas;
    my @attrs;
    for my $a (@{$attrs_tmpl // []}) {
        my $v = $a->{vendor};
        if ($v) {
            push @vsas, {vendor => $v, attribute => $a->{name}, value => $a->{tmpl}->process($vars) };
        } else {
            push @attrs, $a->{name}, $a->{tmpl}->process($vars);
        }
    }

    return (\@attrs, \@vsas);
}

sub makeRadiusAttributes {
    my ($self, $attrs_tmpl, $vars) = @_;
    my @vsas;
    my @attrs;
    for my $a (@{$attrs_tmpl // []}) {
        push @attrs, $a->{name}, $a->{tmpl}->process($vars);
    }

    return \@attrs;
}

=item handleRadiusDeny

Return RLM_MODULE_USERLOCK if the vlan id is -1

=cut

sub handleRadiusDeny {
    my ($self, $args) =@_;
    my $logger = $self->logger();

    if (( defined($args->{'vlan'}) && $args->{'vlan'} eq "-1" ) || ( defined($args->{'user_role'}) && $args->{'user_role'} eq $REJECT_ROLE )) {
        $logger->info("According to rules in fetchRoleForNode this node must be kicked out. Returning USERLOCK");
        $self->disconnectRead();
        $self->disconnectWrite();
        my $attrs = $self->makeRadiusAttributes($self->{_template}->{reject}, $args);
        return [ $RADIUS::RLM_MODULE_USERLOCK, @$attrs ];
    }

    return undef;
}

=item returnRadiusAccessAccept

Prepares the RADIUS Access-Accept response for the network device.

Default implementation.

=cut

sub returnRadiusAccessAccept {
    my ($self, $args) = @_;
    my $logger = $self->logger();

    my $radius_reply_ref = {};

    # should this node be kicked out?
    my $kick = $self->handleRadiusDeny($args);
    return $kick if (defined($kick));

    # Inline Vs. VLAN enforcement
    my %tmp_args = %$args;
    my $role = "";

    if ( (!$tmp_args{'wasInline'} || ($tmp_args{'wasInline'} && $tmp_args{'vlan'} != 0) ) && isenabled($self->{_VlanMap})) {
        my $vlanTemplate = $self->{_template}{acceptVlan};
        if ( defined $vlanTemplate &&  defined($tmp_args{'vlan'}) && $tmp_args{'vlan'} ne "" && $tmp_args{'vlan'} ne 0) {
            $self->updateArgsVariablesForSet(\%tmp_args, $vlanTemplate);
            $logger->info("(".$self->{'_id'}.") Added VLAN $args->{'vlan'} to the returned RADIUS Access-Accept");
            my $attrs = $self->makeRadiusAttributes($vlanTemplate, \%tmp_args);
            $radius_reply_ref = { @$attrs };
        } else {
            $logger->debug("(".$self->{'_id'}.") Received undefined VLAN. No VLAN added to RADIUS Access-Accept");
        }
    }

    if ( isenabled($self->{_RoleMap}) ) {
        $logger->debug("Network device (".$self->{'_id'}.") supports roles. Evaluating role to be returned");
        if ( defined($args->{'user_role'}) && $args->{'user_role'} ne "" ) {
            $role = $self->getRoleByName($args->{'user_role'});
        }
        my $roleTemplate = $self->{_template}{acceptRole};
        $tmp_args{role} = $role;
        if (defined $roleTemplate && defined($role) && $role ne "" ) {
            $self->updateArgsVariablesForSet(\%tmp_args, $roleTemplate);
            my $attrs = $self->makeRadiusAttributes($roleTemplate, \%tmp_args);
            $radius_reply_ref = {
                %$radius_reply_ref,
                @$attrs,
            };
            $logger->info(
                "(".$self->{'_id'}.") Added role $role to the returned RADIUS Access-Accept"
            );
        } else {
            $logger->debug("(".$self->{'_id'}.") Received undefined role. No Role added to RADIUS Access-Accept");
        }
    }

    $self->addAcceptUrlAttributes($radius_reply_ref, \%tmp_args);

    my $status = $RADIUS::RLM_MODULE_OK;
    if (!isenabled($args->{'unfiltered'})) {
        my $filter = pf::access_filter::radius->new;
        my $rule = $filter->test('returnRadiusAccessAccept', $args);
        ($radius_reply_ref, $status) = $filter->handleAnswerInRule($rule,$args,$radius_reply_ref);
    }

    return [$status, %$radius_reply_ref];
}


=head2 addTemplateAttributesToReply

addTemplateAttributesToReply

=cut

sub addTemplateAttributesToReply {
    my ($self, $reply, $templateName, $args) = @_;
    my $template = $self->{_template}{$templateName};
    if (!defined $template) {
        return;
    }

    $self->updateArgsVariablesForSet($args, $template);
    my $attrs = $self->makeRadiusAttributes($template, $args);
    $self->_mergeAttributes($reply, $attrs);
}


=head2 _mergeAttributes

_mergeAttributes

=cut

sub _mergeAttributes {
    my ($self, $radiusReply, $attributes) = @_;
    my ($err, $results);
    foreach my $pair ( pairs @$attributes ) {
        my ( $key, $value ) = @$pair;
        $value = listify($value);
        if (exists $radiusReply->{$key}) {
            my $old_value = listify($radiusReply->{$key});
            push @$old_value, @$value;
            $value = $old_value;
        }

        $radiusReply->{$key} = $value;
    }

    return;
}

sub canDoAcceptUrl {
    my ($self) = @_;
    my $template = $self->{_template};
    return exists $template->{acceptUrl} && defined ($template->{acceptUrl}) &&  isenabled($self->{_UrlMap}) && $self->externalPortalEnforcement();
}

sub addAcceptUrlAttributes {
    my ($self, $reply, $args) = @_;
    if (!$self->canDoAcceptUrl) {
        return;
    }

    my $user_role = $args->{user_role};
    if (!defined $user_role || $user_role eq '') {
        return;
    }

    my $redirect_url = $self->getUrlByName($user_role);
    if (!defined $redirect_url) {
        return;
    }

    $args->{role} = $self->getRoleByName($user_role);
    my $session_id = "sid" . $self->setSession($args);
    $args->{'session_id'} = $session_id;
    $redirect_url .= '/' unless $redirect_url =~ m(\/$);
    $redirect_url .= $session_id;
    $args->{redirect_url} = $redirect_url;
    $self->addTemplateAttributesToReply($reply, 'acceptUrl', $args);

    return;
}

=item radiusDisconnect

Sends a RADIUS Disconnect-Request to the NAS with the MAC as the Calling-Station-Id to disconnect.

Optionally you can provide other attributes as an hashref.

Uses L<pf::util::radius> for the low-level RADIUS stuff.

=cut

# TODO consider whether we should handle retries or not?
sub radiusDisconnect {
    my ($self, $mac, $add_attributes_ref) = @_;
    my $logger = $self->logger();

    # initialize
    $add_attributes_ref = {} if (!defined($add_attributes_ref));

    if (!defined($self->{'_radiusSecret'})) {
        $logger->warn(
            "Unable to perform RADIUS Disconnect-Request on $self->{'_id'}: RADIUS Shared Secret not configured"
        );
        return;
    }

    $logger->info("deauthenticating");
    my $radiusDisconnect = $self->{_template}{radiusDisconnect} // '';
    if (!exists $DISCONNECT_DISPATCH{$radiusDisconnect}) {
        $logger->error(
            "Unable to perform RADIUS Disconnect-Request on $self->{'_id'}: radiusDisconnect method '$radiusDisconnect' is invalid"
        );
        return;
    }
    
    my $response;
    try {
        $response = $DISCONNECT_DISPATCH{$radiusDisconnect}->($self, $mac, $add_attributes_ref);
    } catch {
        chomp;
        $logger->warn("Unable to perform RADIUS Disconnect/CoA Request: $_");
        $logger->error("Wrong RADIUS secret or unreachable network device...") if ($_ =~ /^Timeout/);
    };

    return if (!defined($response));

    return $TRUE if ( ($response->{'Code'} eq 'Disconnect-ACK') || ($response->{'Code'} eq 'CoA-ACK') );

    $logger->warn(
        "Unable to perform RADIUS Disconnect-Request."
        . ( defined($response->{'Code'}) ? " $response->{'Code'}" : 'no RADIUS code' ) . ' received'
        . ( defined($response->{'Error-Cause'}) ? " with Error-Cause: $response->{'Error-Cause'}." : '' )
    );
    return;
}

=head2 handleDisconnect

handleDisconnect

=cut

sub handleDisconnect {
    my ($self, $mac, $add_attributes_ref) = @_;
    my $send_disconnect_to = $self->disconnectAddress($add_attributes_ref);
    my $connection_info = {
        nas_ip => $send_disconnect_to,
        secret => $self->{'_radiusSecret'},
        LocalAddr => $self->deauth_source_ip($send_disconnect_to),
    };

    if (defined($self->{'_disconnectPort'}) && $self->{'_disconnectPort'} ne '') {
        $connection_info->{'nas_port'} = $self->{'_disconnectPort'};
    }

    my $radiusDisconnect = $self->{_template}{disconnect};
    my %args = (
        disconnectIp => $send_disconnect_to,
        mac => $mac,
    );
    $self->updateArgsVariablesForSet(\%args, $radiusDisconnect);
    my ($attrs, $vsa) = $self->makeRadiusAttributesWithVSA($radiusDisconnect, \%args);
    # Standard Attributes
    my $attributes_ref = { @$attrs, %$add_attributes_ref };
    return perform_disconnect($connection_info, $attributes_ref, $vsa);
}

=head2 disconnectAddress

disconnectAddress

=cut

sub disconnectAddress {
    my ($self, $add_attributes_ref) = @_;
    my $logger = $self->logger;
    my $send_disconnect_to = $self->{'_ip'};
    # but if controllerIp is set, we send there
    if (defined($self->{'_controllerIp'}) && $self->{'_controllerIp'} ne '') {
        $logger->info("controllerIp is set, we will use controller $self->{_controllerIp} to perform deauth");
        $send_disconnect_to = $self->{'_controllerIp'};
    }
    # allowing client code to override where we connect with NAS-IP-Address
    if ( defined $add_attributes_ref && defined($add_attributes_ref->{'NAS-IP-Address'}) && $add_attributes_ref->{'NAS-IP-Address'} ne '' ) {
        $logger->info("'NAS-IP-Address' additionnal attribute is set. Using it '" . $add_attributes_ref->{'NAS-IP-Address'} . "' to perform deauth");
        $send_disconnect_to = $add_attributes_ref->{'NAS-IP-Address'};
    }

    return $send_disconnect_to;
}

=head2 handleCoa

handleCoa

=cut

sub handleCoa {
    my ($self, $mac, $add_attributes_ref, $role) = @_;
    my $send_disconnect_to = $self->disconnectAddress($add_attributes_ref);
    my $connection_info = {
        nas_ip => $send_disconnect_to,
        secret => $self->{'_radiusSecret'},
        LocalAddr => $self->deauth_source_ip($send_disconnect_to),
    };

    if (defined($self->{'_coaPort'}) && $self->{'_coaPort'} ne '') {
        $connection_info->{'nas_port'} = $self->{'_coaPort'};
    }

    my $radiusDisconnect = $self->{_template}{coa};
    my %args = (
        disconnectIp => $send_disconnect_to,
        mac => $mac,
        role => $role,
    );
    $self->updateArgsVariablesForSet(\%args, $radiusDisconnect);
    my ($attrs, $vsa) = $self->makeRadiusAttributesWithVSA($radiusDisconnect, \%args);
    # Standard Attributes
    my $attributes_ref = { @$attrs, %$add_attributes_ref };
    return perform_coa($connection_info, $attributes_ref, $vsa);
}

=head2 handleCoaOrDisconnect

handleCoaOrDisconnect

=cut

sub handleCoaOrDisconnect {
    my ($self, $mac, $add_attributes_ref) = @_;
    my $roleResolver = pf::roles::custom->instance();
    my $role = $roleResolver->getRoleForNode($mac, $self);
    if ( $self->shouldUseCoA({role => $role}) ) {
        return $self->handleCoa($mac, $add_attributes_ref, $role);
    }

    return $self->handleDisconnect($mac, $add_attributes_ref);
}

=item deauthTechniques

Return the reference to the deauth technique or the default deauth technique.

=cut

sub deauthTechniques {
    my ($self, $method, $connection_type) = @_;
    my $logger = $self->logger;
    my $default = $SNMP::RADIUS;
    my %tech = (
        $SNMP::RADIUS => 'deauthenticateMacDefault',
    );

    if (!defined($method) || !defined($tech{$method})) {
        $method = $default;
    }
    return $method,$tech{$method};
}

=item supporteddeauthTechniques

return Default Deauthentication Method

=cut

sub supporteddeauthTechniques {
    my ( $self ) = @_;

    my %tech = (
        'Default' => 'deauthenticateMacDefault',
    );
    return %tech;
}

=item deauthenticateMacDefault

return Default Deauthentication Default technique

=cut

sub deauthenticateMacDefault {
    my ( $self, $mac, $is_dot1x ) = @_;
    my $logger = $self->logger;

    if ( !$self->isProductionMode() ) {
        $logger->info("not in production mode... we won't perform deauthentication");
        return 1;
    }

    $logger->debug("deauthenticate $mac using RADIUS Disconnect-Request deauth method");
    return $self->radiusDisconnect($mac);
}

sub updateArgsVariablesForSet {
    my ($self, $args, $set) = @_;
    return if !defined $set;
    pf::mini_template::update_variables_for_set($set, \%LOOKUP, $args, $self, $args);
}

=head2 getVoipVsa

Get Voice over IP RADIUS Vendor Specific Attribute (VSA).

=cut

sub getVoipVsa {
    my ($self) = @_;
    my $logger = $self->logger;
    my $template = $self->{_template}{voip};
    if (!defined $template) {
        return;
    }

    my $attrs = $self->makeRadiusAttributes($template, { switch => $self, vlan => $self->getVlanByName($VOICE_ROLE) });
    return (@{$attrs // []});
}

sub isVoIPEnabled {
    my ($self) = @_;
    return isenabled($self->{_VoIPEnabled}) ;
}

=head2 wiredeauthTechniques

Return the reference to the deauth technique or the default deauth technique.

=cut

sub wiredeauthTechniques {
    my ($self, $method, $connection_type) = @_;
    if(isenabled($self->{_template}->{snmpDisconnect})) {
        return $SNMP::SNMP, 'handleReAssignVlanTrapForWiredMacAuth';
    }
    else {
        return $SNMP::RADIUS, 'deauthenticateMacRadius';
    }
}

=head2 deauthenticateMacRadius

Method to deauth a wired node with CoA.

=cut

sub deauthenticateMacRadius {
    my ($self, $ifIndex, $mac) = @_;
    my $logger = $self->logger();
    if ( !$self->isProductionMode() ) {
        $logger->info("not in production mode... we won't perform deauthentication");
        return 1;
    }

    $logger->debug("deauthenticate $mac using RADIUS Disconnect-Request deauth method");
    $self->radiusDisconnect($mac );
}

=head2 aclTemplate

Override the default ACL template if applicable

=cut

sub aclTemplate {
    my ($self) = @_;
    return $self->{_template}{acl_template} || $DEFAULT_ACL_TEMPLATE
}

sub bouncePort {
    my ($self, $ifindex) = @_;
    my $logger = $self->logger;
    if ( !$self->isProductionMode() ) {
        $logger->info("Switch not in production mode... we won't perform port bounce");
        return $TRUE;
    }

    my $radiusBounce = $self->{_template}{bounce};
    if (!defined $radiusBounce) {
        return $self->SUPER::bouncePort($ifindex);
    }

    return $self->_bouncePortCoa($ifindex, $radiusBounce);
}

sub handleReAssignVlanTrapForWiredMacAuth {
    my ($self, $ifIndex, $mac) = @_;
    return $self->bouncePortSNMP($ifIndex);
}

sub _bouncePortCoa {
    my ($self, $ifIndex, $radiusBounce) = @_;
    my $logger = $self->logger;
    my $id = $self->{_id};

    if (!defined($self->{'_radiusSecret'})) {
        $logger->warn(
            "Unable to perform RADIUS CoA-Request on $id: RADIUS Shared Secret not configured"
        );
        return;
    }

    #We need to fetch the MAC on the ifIndex in order to bounce switch port with CoA.
    my @locationlog = locationlog_view_open_switchport_no_VoIP( $id, $ifIndex );
    my $mac = $locationlog[0]->{'mac'};
    if (!$mac) {
        @locationlog = locationlog_view_open_switchport_only_VoIP( $id, $ifIndex );
        $mac = $locationlog[0]->{'mac'};
    }

    if (!$mac) {
        $logger->info("Can't find MAC address in the locationlog... we won't perform port bounce");
        return $FALSE;
    }

    my $send_disconnect_to = $self->disconnectAddress({});
    my $connection_info = {
        nas_ip => $send_disconnect_to,
        secret => $self->{'_radiusSecret'},
        LocalAddr => $self->deauth_source_ip($send_disconnect_to),
    };
    my %args = (
        disconnectIp => $send_disconnect_to,
        mac => $mac,
        ifIndex => $ifIndex,
        switch => $self,
    );

    $self->updateArgsVariablesForSet(\%args, $radiusBounce);
    my ($attrs, $vsa) = $self->makeRadiusAttributesWithVSA($radiusBounce, \%args);
    # Standard Attributes
    return perform_coa($connection_info, {@$attrs}, $vsa);
}

sub processTemplate {
    my ($self, $template, $templateName, $vars) = @_;
    if (!exists $template->{$templateName}) {
        return undef;
    }

    my $tmpl= $template->{$templateName};
    if (!defined $tmpl) {
        return undef;
    }

    return $tmpl->process($vars);
}

sub NasPortToIfIndex {
    my ($self, $nasPort) = @_;
    my $ifindex = $self->processTemplate($self->{_template}, 'nasPortToIfindex', {nasPort => $nasPort});
    if ($ifindex) {
        return $ifindex;
    }

    return $self->SUPER::NasPortToIfIndex($nasPort);
}

sub returnAuthorizeRead {
    my ($self, $args) = @_;
    return $self->returnCliAuthorize($args, 'Read');
}

sub returnAuthorizeWrite {
    my ($self, $args) = @_;
    return $self->returnCliAuthorize($args, 'Write');
}

sub returnCliAuthorize {
    my ($self, $args, $accessType) = @_;
    my $logger = $self->logger;
    my %radius_reply;
    my $template = $self->{_template}{"cliAuthorize${accessType}"};
    my %tmp_args = %$args;
    if ($template) {
        $self->updateArgsVariablesForSet(\%tmp_args, $template);
        my $attrs = $self->makeRadiusAttributes($template, \%tmp_args);
        %radius_reply = @$attrs;
    } else {
        $radius_reply{'Reply-Message'} = "Switch $accessType access granted by PacketFence";
    }

    $logger->info("User $args->{'user_name'} logged in $args->{'switch'}{'_id'} with $accessType access");
    my $filter = pf::access_filter::radius->new;
    my $rule = $filter->test("returnAuthorize${accessType}", \%tmp_args);
    if ($rule) {
        my ($radius_reply_ref, $status) = $filter->handleAnswerInRule($rule, \%tmp_args, \%radius_reply);
        return [$status, %$radius_reply_ref];
    }

    return [$RADIUS::RLM_MODULE_OK, %radius_reply];
}

=item parseExternalPortalRequest

Parse external portal request using URI and it's parameters then return an hash reference with the appropriate parameters

See L<pf::web::externalportal::handle>

=cut

sub parseExternalPortalRequest {
    my ( $self, $r, $req ) = @_;
    my $logger = $self->logger;
    my $client_ip = defined($r->headers_in->{'X-Forwarded-For'}) ? $r->headers_in->{'X-Forwarded-For'} : $r->connection->remote_ip;
    my $template = $self->_template;
    my %params = (
        synchronize_locationlog => isenabled($template->{webAuthSynchronize}),   # Should we synchronize locationlog
        connection_type         => $template->{webAuthConnectionType},   # Set the connection_type
        client_ip => $client_ip,
    );
    if (isenabled($template->{webAuthUseSession})) {
        $self->parseExternalPortalRequestFromSession(\%params, $r, $req);
    }

    my $table = $req->param;
    my @names = keys %$table;
    my %queryParams;
    @queryParams{@names} = @{$table}{@names};
    my %vars = (
        params => \%queryParams,
        client_ip => $client_ip,
    );

    while (my ($t, $p) = each %WEBAUTH_TEMPLATE_TO_REQUEST_PARAM) {
        my $out = $self->processTemplate($template, $t, \%vars);
        if (!defined $out || length($out) == 0) {
            next;
        }

        $params{$p} = $out;
    }

    return \%params;
}

sub parseExternalPortalRequestFromSession {
    my ($self, $params, $r, $req) = @_;
    my $uri = $r->uri;
    return unless ($uri =~ /.*sid(\w+[^\/\&])/);
    my $session_id = $1;
    my $locationlog = pf::locationlog::locationlog_get_session($session_id);
    $params->{session_id} = $session_id;
    $params->{client_mac} = $locationlog->{mac};
    $params->{switch_id} = $locationlog->{switch};
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
