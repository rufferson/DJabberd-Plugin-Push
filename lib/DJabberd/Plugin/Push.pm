package DJabberd::Plugin::Push;
# vim: sts=4 ai:
use warnings;
use strict;
use base 'DJabberd::Plugin';

use constant {
	PSHNv0 => "urn:xmpp:push:0",
};

our $logger = DJabberd::Log->get_logger();

=head1 NAME

DJabberd::Plugin::Push - Implements XEP-0357 Push Notifications (server part)

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';

=head1 SYNOPSIS

Implements XEP-0357 Push Notifications server part - enable/disable and publish.

    <VHost mydomain.com>
	<Plugin DJabberd::Plugin::Push />
    </VHost>

=head1 METHODS

=head2 register($self, $vhost)

Register the vhost with the module. Sets up hooks at chains c2s-iq, deliver and
ConnectionClosing. As well as adds server feature C<urn:xmpp:push:0>.
=cut

sub run_before {
    return qw(DJabberd::Delivery::Local);
}

my %callmap = (
    'set-{'.PSHNv0.'}enable' => \&enable,
    'set-{'.PSHNv0.'}disable' => \&disable,
    'error-{'.PSHNv0.'}pubsub' => \&error
);
sub register {
    my ($self,$vhost) = @_;
    my $manage_cb = sub {
	my ($vh, $cb, $iq) = @_;
	if(exists $callmap{$iq->signature} && (!$iq->to || $vh->uses_jid($iq->to))) {
	    $callmap{$iq->signature}->($self,$iq);
	    my $xml = "<iq type='result' id='".$iq->id."' to='".$iq->from."'/>";
	    $iq->connection->log_outgoing_data($xml);
	    $iq->connection->write(\$xml);
	    return $cb->stop_chain;
	}
	$cb->decline;
    };
    my $handle_cb = sub {
	my ($vh,$cb,$sz) = @_;
	if($sz->isa('DJabberd::Message') && $sz->from && $sz->to) {
	    my $type = $sz->attr('{}type');
	    # Skip anything but chat, normal or error (well...)
	    return $cb->decline
		unless(!$type
			or $type eq 'chat'
			or $type eq 'normal'
			or $type eq 'error');
	    # Skip bodyless control messages
	    return $cb->decline
		unless(grep {
			$_->element_name eq 'body' && $_->children
		       } $sz->children_elements);
	    $self->handle($sz);
	}
	$cb->decline;
    };
    $self->{vhost} = $vhost;
    Scalar::Util::weaken($self->{vhost});
    # Inject management IQ handler
    $vhost->register_hook("c2s-iq",$manage_cb);
    # Deliver hook will handle outgoing and incoming messages.
    $vhost->register_hook("deliver",$handle_cb);
    $vhost->register_hook("DiscoBare", sub {
	my ($vh,$cb,$iq,$disco,$bare,$from,$ri) = @_;
	if($disco eq 'info' && $bare->as_bare_string eq $from->as_bare_string) {
	    $cb->addFeatures(PSHNv0);
	}
    });
    $self->{reg} = {};
}

sub vh {
    return $_[0]->{vhost};
}

=head2 $self->enable($jid)

This method enables push notifications for current session represented by full
jid.
=cut

sub enable {
    my ($self,$iq) = @_;
    my $jid = $iq->connection->bound_jid;
    my $el = $iq->first_element;
    my $srv = $el->attr('{}jid');
    my $node = $el->attr('{}node');
    my $form;
    if($el->first_element) {
	$form = DJabberd::Form->new($el->first_element);
	$form = undef if($form->form_type ne 'http://jabber.org/protocol/pubsub#publish-options');
    }
    $logger->debug("Enabling Push Notifications for ".$jid->as_string." to $srv as $node");
    $self->{reg}->{$jid->as_bare_string} = {} unless($self->{reg}->{$jid->as_bare_string});
    $self->{reg}->{$jid->as_bare_string}->{$jid->as_string} = [ $srv, $node, $form ];
}

=head2 $self->disable($jid)

The method disables push notifications on the session represented by full $jid.
=cut

sub disable {
    my ($self,$iq) = @_;
    my $jid = $iq->connection->bound_jid;
    if($self->{reg}->{$jid->as_bare_string}) {
	$logger->debug("Disabling Push Notifications for ".$jid->as_string." to ".$self->{reg}->{$jid->as_bare_string}->{$jid->as_string}->[0]);
	delete $self->{reg}->{$jid->as_bare_string}->{$jid->as_string};
	delete $self->{reg}->{$jid->as_bare_string} unless(keys(%{$self->{reg}->{$jid->as_bare_string}}));
    }
}

=head2 $self->is_enabled($jid)

The method returns true if given $jid has carbons enabled for the session.
=cut

sub is_enabled {
    my ($self,$jid) = @_;
    return (exists $self->{reg}->{$jid->as_bare_string} && $self->{reg}->{$jid->as_bare_string}->{$jid->as_string});
}

=head2 $self->enabled($jid)

This will return all users of the bare $jid which have their push notifications
enabled if either jid is bare or plugin is not in strict notification mode
(default).
Otherwise returns array with single element containing specific session for
full jid or empty array.
=cut

sub enabled {
    my ($self,$jid) = @_;
    return () unless(exists $self->{reg}->{$jid->as_bare_string} && ref($self->{reg}->{$jid->as_bare_string}));
    if(!$self->{strict} || $jid->is_bare) {
	return values(%{$self->{reg}->{$jid->as_bare_string}});
    } elsif($self->is_enabled($jid)) {
	return ($self->{reg}->{$jid->as_bare_string}->{$jid->as_string});
    }
    return ();
}
=head2 wrap($msg,$from,$to,$dir)

This static methods wraps message $msg into carbons <sent> or <received> tags
represented by $dir argument. $from and $to should represent corresponding
bare and full jid of the user which enabled carbons.
=cut

sub wrap {
    my ($self,$form,$from,$to,$node,@cust) = @_;
    my $ret = DJabberd::IQ->new('','iq',
	{ '{}from' => $from, '{}to' => $to },
	[ DJabberd::XMLElement->new('http://jabber.org/protocol/pubsub','pubsub',{},[
	    DJabberd::XMLElement->new(undef,'publish',{node=>$node},[
		DJabberd::XMLElement->new(undef,'item',{},[
		    DJabberd::XMLElement->new(PSHNv0,'notification',{},[ $form ])
		])
	    ])
	  ])
	]
    );
    $ret->set_attr('{}id', "pshn-iq-".(10*$self->{idseq}++)+int(rand(10)));
    return $ret;
}

=head2 $self->handle($msg)

The method handles message delivery to CC it to enabled resources.

If message is eligible and not private - it is wrapped and delivered to all
matching C<from> and C<to> local users which enabled the carbons.
Eligibility is checked at callback handler in the register method.
=cut

sub handle {
    my ($self,$msg) = @_;
    my $type = $msg->attr('{}type');
    my $from = $msg->from_jid;
    my $to = $msg->to_jid;
    my @to = $self->enabled($to);
    return unless(@to);
    $logger->debug("Pushing to ".join(', ',@to));
    foreach my$push(@to) {
	my $form = DJabberd::Form->new('submit',[
	    {var=>'FORM_TYPE', value=>['urn:xmpp:push:summary'], type=>'hidden'},
	    {var=>'message-count',value=>[1]},
	    {var=>'last-message-sender',value=>[$from->as_bare_string]},
	    {var=>'last-message-body',value=>['yes']}
	]);
	my $pub = $self->wrap($form,$to->as_bare_string,$push->[0],$push->[1]);
	if($push->[2] && ref($push->[2])) {
	    $pub->first_element->push_child(DJabberd::XMLElement->new(undef,'publish-options',{},[$push->[2]]));
	}
	$pub->deliver($self->vh);
    }
}

=head1 AUTHOR

Ruslan N. Marchenko, C<< <me at ruff.mobi> >>

=head1 COPYRIGHT & LICENSE

Copyright 2016 Ruslan N. Marchenko, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.
=cut
1;
