package MultiProcessBooks;

use Modern::Perl '2017';

use utf8;

use Exporter::Easy (
  EXPORT => [ qw( DEBUG_MSG ) ],
);

use Carp;
use Data::Dumper;
use List::Util qw( sum );
use Parallel::ForkManager;
use Sys::Info;
use String::Elide::Parts qw(elide);
use Term::ANSIColor qw( color colorstrip );
use Term::Size;


sub new {
    my ($class, %args) = @_;

    my $self =
        {dir        => ( $args{dir}       // croak "Missing arg dir" ),
         num_tasks  => $args{num_tasks} || get_num_tasks(),
         pm         => undef,
         tasks      => {},
         task_order => [],
         queue      => [],
         printed    => 0,
         display    => { what   => 10,
                         author => 20,
                         book   => 0,   # Set later
                         status => 15,
                         FIXED  => 8,   # The number of fixed chars in the string
                       },
        };
    bless($self, $class);

    $self->{pm} = Parallel::ForkManager->new( $self->{num_tasks} );
    $self->{pm}->run_on_finish(
        sub {
            my ($pid, $exit_code, $ident, $exit_signal, $core_dump, $res) = @_;

            # retrieve data structure from child
            if (defined($res)) {  # children are not forced to send anything
                $self->get_task($ident)->{dur} = $res->{dur};
            }
            else {  # problems occurring during storage or retrieval will throw a warning
                print qq|No message received from child process $pid!\n|;
            }

            # Kick off any remaining tasks
            $self->start_jobs();
        });


    # Set up the display stuff
    my ($columns) = Term::Size::chars();
    my $d = $self->{display};
    $d->{book} = $columns - sum(values %$d);
    $d->{book} = 15 if $d->{book} < 15;

    return $self;
}


sub get_num_tasks {
    # No args

    my $info = Sys::Info->new;
    my $cpu  = $info->device('CPU');

    return $cpu->count();
}

sub get_task {
    my ($self, $s) = @_;

    my $t = $self->{tasks}{$s}
        or croak "No task '$s'";

    return $t;
}

sub start_jobs {
    my ($self) = @_;

    # Prime the work queue
    my $pm = $self->{pm};
    while (@{ $self->{queue} } and $pm->running_procs < $pm->max_procs) {
        $self->start_job(shift @{ $self->{queue} });
    }

    return;
}

sub start_job {
    my ($self, $s) = @_;

    $self->get_task($s)->{started} = time;

    my $pm = $self->{pm};
    $pm->start($s)
        and return;

    my $start = time;

    system($self->get_task($s)->{cmd});

    my $dur = time - $start;

    $pm->finish($?, {dur => $dur});

    return;
}

sub wait_for_task {
    my ($self, $s) = @_;

    # Loop waiting for the task to complete
    my $t;
  WAIT_LOOP:
    while (1) {
        $self->{pm}->reap_finished_children();

        $t = $self->get_task($s)
            or die "No task '$s'";

        last WAIT_LOOP
            if defined $t->{dur};

         # Update the status line
         $self->print_status($s);

         sleep 0.1;
    }

    return $t;
}

sub _print_status {
    my ($self, $str) = @_;

    my $printed = $self->{printed};

    print "\b"x$printed;
    print  " "x$printed;
    print "\b"x$printed;

    print $str;

    STDOUT->flush();

    # If this was the end of the line, there's no status length
    $self->{printed} = $str =~ /\R\z/ ? 0 : length(colorstrip($str));

    return;
}

sub print_task_start {
    my ($self, $s) = @_;

    my $i = $self->get_task($s);

    my ($skip, $author, $book )
        = @{$i}{qw{ skip author book }};

    my $d = $self->{display};

    my ($what, $wcolor) = $skip ? ("Skipping", "yellow") : ("Processing", "bold green");
    my $acolor = "bold blue";
    my $bcolor = "bold blue";
    my ($w, $a, $b) = map { "$_.$_" } @{$d}{qw( what author book )};
    printf("%s%${w}s%s: %s%${a}s%s - %s%-${b}s%s  ",
           color($wcolor), $what,                        color('reset'),
           color($acolor), elide($author, $d->{author}), color('reset'),
           color($bcolor), elide($book,   $d->{book}  ), color('reset'),
          );
    STDOUT->flush();

    return;
}

sub print_task_end {
    my ($self, $s) = @_;

    my $i = $self->get_task($s);

    my $status = "\n";
    $status = sprintf(" %sDone%s: %s%3ds%s\n",
                      color('bold green'),            color('reset'),
                      color('bold blue'),  $i->{dur}, color('reset'),
                      )
        unless $i->{skip};

    $self->_print_status($status);

    return;
}

sub print_status {
    my ($self, $cur_task) = @_;

    my $short_count = 0;
    my $long_count  = 0;
    my $done_count  = 0;

    my $time = time;

    my $found = 0;
    my @tasks;
    foreach my $s (@{ $self->{task_order} }) {
        $found = 1 if $s eq $cur_task;
        next unless $found;

        my $t = $self->get_task($s);

        # Ignore ones we are skipping
        next if $t->{skip};

        # Ignore ones we haven't started
        my $start = $t->{started};
        next if not defined $start;

        # Add a . for done, o for short running, and 0 for long, and ! for very long
        if (defined $t->{dur}) {
            $done_count++;
            push @tasks, color('bold green').".".color('reset');
        }
        elsif (time - $start < 30) {
            $short_count++;
            push @tasks, color('bold red').  "o".color('reset');
        }
        else {
            $long_count++;
            if (time - $start < 60) {
                push @tasks, color('bold red').  "0".color('reset');
            }
            else {
                push @tasks, color('bold red').  "!".color('reset');
            }
        }
    }

    my $len = $self->{display}{status} - 2;

    # Pad out the tasks if needed
    if (@tasks < $len) {
        push @tasks, (' ')x($len-@tasks);
    }
    elsif (@tasks > $len) {
        # We got too big, flip the display
        @tasks = ();

        $tasks[0] = sprintf("%s%ds+%dl%s &%s %dd%s",
                            color('bold red'),   $short_count,  $long_count, color('reset'),
                            color('bold green'), $done_count,                color('reset'),
                           );

        my $pad = $len - length(colorstrip($tasks[0]));
        $tasks[0] .= " "x$pad
            if $pad > 0;
    }
    my $str = join '', @tasks;

    my @bc = (color('bold blue'), color('reset'));
    my $status = sprintf("%s[%s%s%s]%s", @bc, $str, @bc);
    $self->_print_status($status);

    return;
}

sub run_jobs {
    my ($self) = @_;

    $self->start_jobs();

    foreach my $s (@{ $self->{task_order} }) {
        $self->print_task_start($s);
        $self->wait_for_task($s);
        $self->print_task_end($s);
    }

    return;
}

sub add_task {
    my ($self, $task_name, %args) = @_;

    my @av = qw( skip author book cmd );
    foreach my $a (@av) {
        croak "Missing arg '$a'"
            unless defined $args{$a};
    }
    croak "Extra args" if keys %args != @av;

    push @{ $self->{task_order} }, $task_name;
    push @{ $self->{queue}      }, $task_name
        unless $args{skip};

    $self->{tasks}{$task_name} =
        {skip     => $args{skip},
         author   => $args{author},
         book     => $args{book},
         cmd      => $args{cmd},

         dur      => $args{skip} ? 0    : undef,
         started  => undef,
        };

    return;
}


sub add_sources {
    my ($self, $force, $which, $sources) = @_;

    my $dir = $self->{dir};

  SOURCE_LOOP:
    foreach my $s (@$sources) {
        my ($author, $book) = split m{/}, $s
            or die "Unable to process '$s'";
        (my $ob = $book) =~ s{_ .*}{};
        my $cmd = "./find_times.pl ~/\QCalibre Library\E/\Q$author\E/\Q$book (\E*\Q)\E/*epub" .
            " > $dir/\Q$author - $ob.dmp";

        my $skip = 0;
        my $file = "$dir/$author - $ob.dmp";
        if (-f $file and not -z $file and not $force and
            ( not $which or "$author - $ob" !~ /$which/i)
            )
        {
            $skip = 1;
        }

        $self->add_task($s,
                        skip     => $skip,
                        author   => $author,
                        book     => $ob,
                        cmd      => $cmd,
                       );
    }

    return;
}

sub DEBUG_MSG {
    my @dump = @_;

    my ($package, $filename, $line) = caller;

    local $Data::Dumper::Indent = 1;
    local $Data::Dumper::Sortkeys = 1;
    print STDERR "Debug at $filename:$line:\n", Dumper(@dump);

    return;
}

1;
