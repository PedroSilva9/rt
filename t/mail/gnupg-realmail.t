#!/usr/bin/perl
use strict;
use warnings;
use Test::More tests => 160;
use File::Temp;
use RT::Test;
use Cwd 'getcwd';
use String::ShellQuote 'shell_quote';
use IPC::Run3 'run3';

my $homedir = File::Spec->catdir( getcwd(), qw(lib t data crypt-gnupg-mail) );

RT->Config->Set( LogToScreen => 'debug' );
RT->Config->Set( 'GnuPG',
                 Enable => 1,
                 OutgoingMessagesFormat => 'RFC' );

RT->Config->Set( 'GnuPGOptions',
                 homedir => $homedir );

RT->Config->Set( 'MailPlugins' => 'Auth::MailFrom', 'Auth::GnuPG' );

my ($baseurl, $m) = RT::Test->started_ok;
ok(my $user = RT::User->new($RT::SystemUser));
ok($user->Load('root'), "Loaded user 'root'");
$user->SetEmailAddress('rt-test@example.com');

my $eid = 0;
for my $usage (qw/signed encrypted signed&encrypted/) {
    for my $format (qw/MIME inline/) {
        for my $attachment (qw/plain text-attachment binary-attachment/) {
            ++$eid;
            diag "Email $eid: $usage, $attachment email with $format key" if $ENV{TEST_VERBOSE};
            my $ok = eval { email_ok($eid, $usage, $format, $attachment) };
            ok($ok, "$usage, $attachment email with $format key");
        }
    }
}

sub get_contents {
    my $eid = shift;

    my ($file) = glob("lib/t/data/mail/$eid-*");
    defined $file
        or do { diag "Unable to find lib/t/data/mail/$eid-*"; return };

    open my $mailhandle, '<', $file
        or do { diag "Unable to read $file: $!"; return };

    my $mail = do { local $/; <$mailhandle> };
    close $mailhandle;

    return $mail;
}

sub email_ok {
    my ($eid, $usage, $format, $attachment) = @_;

    my $mail = get_contents($eid)
        or return 0;

    my ($status, $id) = RT::Test->send_via_mailgate($mail);
    is ($status >> 8, 0, "The mail gateway exited normally");

    my $tick = get_latest_ticket_ok();
    is( $tick->Subject,
        "Test Email ID:$eid",
        "Created the ticket"
    );

    my $txn = $tick->Transactions->First;
    my ($msg, @attachments) = @{$txn->Attachments->ItemsArrayRef};

    if ($usage =~ /encrypted/) {
        is( $msg->GetHeader('X-RT-Incoming-Encryption'),
            'Success',
            'recorded incoming mail that is encrypted'
        );
        is( $msg->GetHeader('X-RT-Privacy'),
            'PGP',
            'recorded incoming mail that is encrypted'
        );

        #XXX: maybe RT will have already decrypted this for us
        unlike( $msg->Content,
                qr/ID:$eid/,
                'incoming mail did NOT have original body'
        );
    }
    else {
        is( $msg->GetHeader('X-RT-Incoming-Encryption'),
            'Not encrypted',
            'recorded incoming mail that is not encrypted'
        );
        like( $msg->Content || $attachments[0]->Content,
              qr/ID:$eid/,
              'got original content'
        );
    }

    if ($usage =~ /signed/) {
        is( $msg->GetHeader('X-RT-Incoming-Signature'),
            'RT Test <rt-test@example.com>',
            'recorded incoming mail that is signed'
        );
    }
    else {
        is( $msg->GetHeader('X-RT-Incoming-Signature'),
            undef,
            'recorded incoming mail that is not signed'
        );
    }

    if ($attachment =~ /attachment/) {
        my $attachment = $attachments[0];
        my $file = '';
        ok ($attachment->Id, 'loaded attachment object');
        my $acontent = $attachment->Content;
        is ($acontent, $file, 'The attachment isn\'t screwed up in the database.');

        # signed messages should sign each attachment too
        if ($usage =~ /signed/) {
            my $sig = $attachments[1];
            ok ($attachment->Id, 'loaded attachment.sig object');
            my $acontent = $attachment->Content;
        }
    }

    return 0;
}

sub get_latest_ticket_ok {
    my $tickets = RT::Tickets->new($RT::SystemUser);
    $tickets->OrderBy( FIELD => 'id', ORDER => 'DESC' );
    $tickets->Limit( FIELD => 'id', OPERATOR => '>', VALUE => '0' );
    my $tick = $tickets->First();
    ok( $tick->Id, "found ticket " . $tick->Id );
    return $tick;
}

