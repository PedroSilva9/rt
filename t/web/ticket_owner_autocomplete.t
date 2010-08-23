#!/usr/bin/perl

use strict;
use warnings;

use RT::Test tests => 39;
use JSON qw(from_json);

my $queue = RT::Test->load_or_create_queue( Name => 'Regression' );
ok $queue && $queue->id, 'loaded or created queue';

my $user_a = RT::Test->load_or_create_user(
    Name => 'user_a', Password => 'password',
);
ok $user_a && $user_a->id, 'loaded or created user';

my $user_b = RT::Test->load_or_create_user(
    Name => 'user_b', Password => 'password',
);
ok $user_b && $user_b->id, 'loaded or created user';

RT->Config->Set( AutocompleteOwners => 1 );
RT::Test->started_ok;

ok( RT::Test->set_rights(
    { Principal => $user_a, Right => [qw(SeeQueue ShowTicket CreateTicket ReplyToTicket)] },
    { Principal => $user_b, Right => [qw(SeeQueue ShowTicket OwnTicket)] },
), 'set rights');

my $agent_a = RT::Test::Web->new;
ok $agent_a->login('user_a', 'password'), 'logged in as user A';

diag "current user has no right to own, nobody selected as owner on create" if $ENV{TEST_VERBOSE};
{
    $agent_a->get_ok('/', 'open home page');
    $agent_a->form_name('CreateTicketInQueue');
    $agent_a->select( 'Queue', $queue->id );
    $agent_a->submit;

    $agent_a->content_like(qr/Create a new ticket/i, 'opened create ticket page');
    my $form = $agent_a->form_name('TicketCreate');
    is $form->value('Owner'), $RT::Nobody->Name, 'correct owner selected';
    autocomplete_lacks( 'RT::Queue-'.$queue->id, 'user_a' );
    $agent_a->submit;

    $agent_a->content_like(qr/Ticket \d+ created in queue/i, 'created ticket');
    my ($id) = ($agent_a->content =~ /Ticket (\d+) created in queue/);
    ok $id, 'found id of the ticket';

    my $ticket = RT::Ticket->new( $RT::SystemUser );
    $ticket->Load( $id );
    ok $ticket->id, 'loaded the ticket';
    is $ticket->Owner, $RT::Nobody->id, 'correct owner';
}

diag "user can chose owner of a new ticket" if $ENV{TEST_VERBOSE};
{
    $agent_a->get_ok('/', 'open home page');
    $agent_a->form_name('CreateTicketInQueue');
    $agent_a->select( 'Queue', $queue->id );
    $agent_a->submit;

    $agent_a->content_like(qr/Create a new ticket/i, 'opened create ticket page');
    my $form = $agent_a->form_name('TicketCreate');
    is $form->value('Owner'), $RT::Nobody->Name, 'correct owner selected';

    autocomplete_contains( 'RT::Queue-'.$queue->id, 'user_b' );
    $form->value('Owner', $user_b->Name);
    $agent_a->submit;

    $agent_a->content_like(qr/Ticket \d+ created in queue/i, 'created ticket');
    my ($id) = ($agent_a->content =~ /Ticket (\d+) created in queue/);
    ok $id, 'found id of the ticket';

    my $ticket = RT::Ticket->new( $RT::SystemUser );
    $ticket->Load( $id );
    ok $ticket->id, 'loaded the ticket';
    is $ticket->Owner, $user_b->id, 'correct owner';
}

my $agent_b = RT::Test::Web->new;
ok $agent_b->login('user_b', 'password'), 'logged in as user B';

diag "user A can not change owner after create" if $ENV{TEST_VERBOSE};
{
    my $ticket = RT::Ticket->new( $user_a );
    my ($id, $txn, $msg) = $ticket->Create(
        Queue => $queue->id,
        Owner => $user_b->id,
        Subject => 'test',
    );
    ok $id, 'created a ticket #'. $id or diag "error: $msg";
    is $ticket->Owner, $user_b->id, 'correct owner';

    # try the following group of tests twice with different agents(logins)
    my $test_cb = sub {
        my $agent = shift;
        $agent->get("/Ticket/Modify.html?id=$id");
        my $form = $agent->form_number(3);
        is $form->value('Owner'), $user_b->Name, 'correct owner selected';
        $form->value('Owner', $RT::Nobody->Name);
        $agent->submit;

        $agent->content_like(
            qr/Permission denied/i,
            'no way to change owner after create if you have no rights'
        );

        my $ticket = RT::Ticket->new( $RT::SystemUser );
        $ticket->Load( $id );
        ok $ticket->id, 'loaded the ticket';
        is $ticket->Owner, $user_b->id, 'correct owner';
    };

    $test_cb->($agent_a);
    diag "even owner(user B) can not change owner" if $ENV{TEST_VERBOSE};
    $test_cb->($agent_b);
}

diag "on reply correct owner is selected" if $ENV{TEST_VERBOSE};
{
    my $ticket = RT::Ticket->new( $user_a );
    my ($id, $txn, $msg) = $ticket->Create(
        Queue => $queue->id,
        Owner => $user_b->id,
        Subject => 'test',
    );
    ok $id, 'created a ticket #'. $id or diag "error: $msg";
    is $ticket->Owner, $user_b->id, 'correct owner';

    $agent_a->goto_ticket( $id );
    $agent_a->follow_link_ok({text => 'Reply'}, 'Ticket -> Basics');

    my $form = $agent_a->form_number(3);
    is $form->value('Owner'), '', 'empty value selected';
    $agent_a->submit;

    $ticket = RT::Ticket->new( $RT::SystemUser );
    $ticket->Load( $id );
    ok $ticket->id, 'loaded the ticket';
    is $ticket->Owner, $user_b->id, 'correct owner';
}

sub autocomplete {
    my $limit = shift;
    my $agent = shift;
    $agent->get("/Helpers/Autocomplete/Owners?term=&limit=$limit&return=Name", "fetched autocomplete values");
    return from_json($agent->content);
}

sub autocomplete_contains {
    my $limit = shift;
    my $expected = shift;
    my $agent = shift;
    
    unless ( $agent ) {
        $agent = RT::Test::Web->new;
        $agent->login('user_a', 'password');
    }
    
    my $results = autocomplete( $limit, $agent );

    my %seen;
    $seen{$_->{value}}++ for @$results;
    $expected = [$expected] unless ref $expected eq 'ARRAY';
    is((scalar grep { not $seen{$_} } @$expected), 0, "got all expected values");
}

sub autocomplete_lacks {
    my $limit = shift;
    my $lacks = shift;
    my $agent = shift;
    
    unless ( $agent ) {
        $agent = RT::Test::Web->new;
        $agent->login('user_a', 'password');
    }
    
    my $results = autocomplete( $limit, $agent );

    my %seen;
    $seen{$_->{value}}++ for @$results;
    $lacks = [$lacks] unless ref $lacks eq 'ARRAY';
    is((scalar grep { $seen{$_} } @$lacks), 0, "didn't get any unexpected values");
}

