#${PMpre} NCM::Component::shorewall${PMpost}

use parent qw(NCM::Component CAF::Path);

use LC::Exception qw(SUCCESS);
our $EC = LC::Exception::Context->new->will_store_all;

our $NoActionSupported = 1;

use CAF::Process;
use EDG::WP4::CCM::TextRender;

use Readonly;

# shorewall is shorewall.conf
Readonly::Array my @SUPPORTED => qw(shorewall rules zones interfaces policy tcinterfaces tcpri);

Readonly my $CONFIG_DIR => "/etc/shorewall";
Readonly my $BACKUP_SUFFIX => '.quattor.';
Readonly my $FAILED_SUFFIX => '.failed.';
Readonly my $SHOREWALL_CHECK => ['/sbin/shorewall', 'check', $CONFIG_DIR];
Readonly my $SHOREWALL_TRY => ['/sbin/shorewall', 'try', $CONFIG_DIR];
Readonly my $CCM_FETCH => [qw(/usr/sbin/ccm-fetch)];

# Generate new config files, keep backups
# Return undef on failure, the filename if file was modified, or 0 otherwise.
sub make_config
{
    my ($self, $feat, $config, $ts) = @_;

    my $filename = "$CONFIG_DIR/$feat";
    $filename .= '.conf' if $feat eq 'shorewall';

    my $trd = EDG::WP4::CCM::TextRender->new(
        $feat,
        $config->getElement($self->prefix()."/$feat"),
        relpath => 'shorewall',
        log => $self,
        );

    my $fh = $trd->filewriter($filename, log => $self, mode => 0600, backup => $BACKUP_SUFFIX.$ts);
    if(! defined($fh)) {
        $self->error("Failed to render $feat shorewall config: $trd->{fail}");
        return;
    }

    return $fh->close() ? $filename : 0;
}

# Restore nackup of all changed files, do a shorewall try
sub rollback
{
    my ($self, $ts, @changed) = @_;

    my $back_suff = $BACKUP_SUFFIX.$ts;
    my $fail_suff = $FAILED_SUFFIX.$ts;

    my $fail;
    # We will try to roll back as much as possible, and only fail afterwards
    foreach my $filename (@changed) {
        # Move/copy to .failed.timestamp
        # warn only, nothing really bad
        if (! $self->move($filename, $filename.$fail_suff)) {
            $self->warn("Failed to move failed config $filename to $filename$fail_suff: $self->{fail}");
        }

        if ($self->file_exists($filename.$back_suff)) {
            my $msg = "backup config $filename$back_suff to $filename";
            # Restore the $BACKUP_SUFFIX file
            # use '' to disable backup from move
            if ($self->move($filename.$back_suff, $filename, '')) {
                $self->verbose("Restored $msg")
            } else {
                $self->error("Failed to restore $msg: $self->{fail}");
                $fail = 1;
            }
        } else {
            # No backup, must have been new file
            my $msg = "$filename (nothing to restore)";
            if ($self->cleanup($filename)) {
                $self->verbose("Removed $msg")
            } else {
                $self->error("Failed to cleanup $msg: $self->{fail}");
                $fail = 1;
            }
        }
    }

    # No arguments required for try_rollback this time, not going to trigger another rollback
    if ($fail || ! $self->try_rollback()) {
        return;
    } else {
        return SUCCESS;
    };
}

# use shorewall try (check exit code)
#   on fail, rollback backups, and re-try (or restart)?
#   on success, check ccm-fetch
#      on fail, rollback backups, and re-try (or restart)?
# even if changed list is empty, shorewall try and ccm-fetch are called
#   This is useful for rollback method to make the rolled-back files active.
#   But do not call this in Configure if you know nothing was modified.
sub try_rollback
{
    my ($self, $ts, @changed) = @_;

    if (@changed) {
        $self->verbose("Changed config files: ", join(', ', @changed));
    } else {
        $self->verbose("No changed config files passed, going to try the current existing files");
    }

    my ($ec, $output);
    $output = CAF::Process->new($SHOREWALL_CHECK, log => $self)->output();
    if ($? || $output =~ m/^\s*ERROR/m) {
        $self->error("shorewall check failed (ec $?): $output");
    } else {
        $output = CAF::Process->new($SHOREWALL_TRY, log => $self)->output();
        if ($? || $output =~ m/^\s*ERROR/m) {
            $self->error("shorewall try failed (ec $?): $output");
        } else {
            # Let network recover
            sleep 15;
            $output = CAF::Process->new($CCM_FETCH, log => $self)->output();
            if ($?) {
                $self->error("ccm-fetch failed (ec $?): $output");
            } else {
                $self->verbose("shorewall succesfully checked/tried");
                $ec = SUCCESS;
            }
        }
    }

    # Do not return the rollback return value
    $self->rollback($ts, @changed) if (! $ec) && @changed;

    return $ec;
}

sub Configure
{
    my ($self, $config) = @_;

    my $tree = $config->getTree($self->prefix());

    # use a timestamp to distinguish all backupfiles as from current run
    my $ts = time();

    # List of filenames that were changed.
    # These are the files that have to be rolled-back in case of failure
    my @changed;
    foreach my $feat (@SUPPORTED) {
        if ($tree->{$feat}) {
            my $res = $self->make_config($feat, $config, $ts);
            push(@changed, $res) if $res;
        }
    }

    if (@changed) {
        $self->try_rollback($ts, @changed);
    } else {
        $self->verbose("No files were changed");
    }

    return 1;
}

# Required for end of module
1;
