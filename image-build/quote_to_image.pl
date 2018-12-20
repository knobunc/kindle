#!/bin/env perl

use Modern::Perl '2017';

use utf8;
use open ':std', ':encoding(UTF-8)';

use Cwd qw(abs_path);
use Data::Dumper;
use GD;
use Image::Magick;
use List::Util qw( min max );
use Parallel::ForkManager;
use Sys::Info;
use Text::CSV;

# Set up our fonts
$ENV{GDFONTPATH} = abs_path("./fonts");
my $font_path       = "LinLibertine_RZah";
my $font_path_bold  = "LinLibertine_RBah";
my $creditFont      = "LinLibertine_RZIah";
my $creditFont_size = 18;

# Image dimensions
my $width  = 600;
my $height = 800;

# Text margin
my $margin = 26;

# Bounds on the font sizes
# A long quote of 125 words or 700 characters gives us a font size of 23, so 18 is a safe min
my $min_font_size =  18;
my $max_font_size = 120;

# Run it
exit main(@ARGV);

#####

sub main {
    my ($csv_file, $image_path) = @_;
    die "Usage: $0 <csv_file> <output_dir>\n"
        unless $image_path;

    my $csv = Text::CSV->new ( { binary => 1, sep_char => '|', strict => 1 } )
        or die "Cannot use CSV: ".Text::CSV->error_diag ();

    my $fh = IO::File->new($csv_file, '<:encoding(utf8)')
        or die "Can't read '$csv_file': $!";

    my $pm = Parallel::ForkManager->new(get_num_tasks());

    my @tasks;
    my $row_num = -1;
  LOAD_LOOP:
    while (my $row = $csv->getline($fh)) {
        $row_num++;

#        last if $row_num == 50;
#        next if $row_num != 27;

        my ($time, $timestr, $quote, $title, $author) = map { clean_space($_) } @$row;

        $time =~ s{\A (\d\d) : (\d\d) \z}{$1$2}x
            or die "Bad time '$time'";

        my $imagenumber = get_imagenumber($time);
        push @tasks, [$time, $timestr, $quote, $title, $author, $imagenumber, $row_num];
    }

  TASK_LOOP:
    while (@tasks) {
        my @subtasks = splice(@tasks, 0, 20);

        $pm->start()
            and next TASK_LOOP;

        foreach my $t (@subtasks) {
            my ($time, $timestr, $quote, $title, $author, $imagenumber, $row_num) = @$t;
            make_quote_images($image_path, $time, $quote, $timestr, $title, $author,
                              $imagenumber, $row_num);
        }

        $pm->finish();
    }

    $pm->wait_all_children();

    return 0;
}

sub clean_space {
    my ($str) = @_;

    $str =~ s/^\s+|\s+$//g;
    $str =~ s{\s+}{ };

    return $str;
}

sub get_imagenumber {
    my ($time) = @_;

    # Serial number for when there is more than one quote for a certain minute
    state $imagenumber = 0;
    state $previoustime = 0;
    if ($time == $previoustime) {
        $imagenumber++;
    } else {
        $imagenumber = 0;
    }
    $previoustime = $time;

    return $imagenumber;
}

sub make_quote_images {
    my ($image_path, $time, $quote, $timestr, $title, $author, $imagenumber, $ln) = @_;

    ## QUOTE
    # Render the text nicely and return the image handle
    my ($img, $font_size) = render_text($quote, $timestr);

    my $ql = 70;
    my $qs = length($quote) > $ql ? substr($quote, 0, $ql-3) . "..." : $quote;
    printf("%s_%03d (len %5d, font %3d): %s\n",
           $time, $imagenumber, length($quote), $font_size, $qs);

    # Save the image
    my $basename = sprintf("quote_%s_%03d", $time, $imagenumber);
    my $file_nc = $basename.'.png';
    imgtopng($img, "$image_path/$file_nc");

    ## METADATA
    # create another version, with title and author in the image
    add_source($img, $title, $author);

    # Save the image with metadata
    my $file_c = $basename.'_credits.png';
    imgtopng($img, "$image_path/metadata/$file_c");

    $img = undef;

    return;
}

sub imgtopng {
    my ($img, $file) = @_;

    open my $fh, '>:raw', $file
        or die "Unable to write to '$file': $!";
    print $fh $img->png();
    close $fh;

    colorimg_to_grey($file);

    return;
}

sub render_text {
    my ($quote, $timestr) = @_;

    # Get the word pieces
    my $pieces = get_word_pieces($quote, $timestr);

    # Do a binary search of the space
    my $hi_font = $max_font_size;
    my $lo_font = $min_font_size;

    my $font_size;

    while ($lo_font < $hi_font ) {
        $font_size = $lo_font + int(($hi_font - $lo_font) / 2 + 0.5);


        my ($paragraphHeight) = fit_text($pieces, $font_size);

        if ($paragraphHeight) {
            # This font fit, make it the new low
            $lo_font = $font_size;
        }
        else {
            # This font did not fit, make it one above the new high
            $hi_font = $font_size - 1;
        }
    }
    $font_size = $lo_font;

    # Render at the size we found
    my $img = draw_text($pieces, $font_size);

    return ($img, $font_size);
}

sub get_word_pieces {
    my ($quote, $timestr) = @_;

    # First, find the timestr to be highlighted in the quote
    my $ts_loc = index( lc($quote), lc($timestr) );
    die "Unable to find '$timestr' in '$quote'" if $ts_loc == -1;

    # Need the -1 to make split match the trailing spaces
    my @li = split(/\s/, substr($quote, 0, $ts_loc), -1);

    # Determine the position of the timestr in the quote (which word it is first in)
    my $timestr_starts = @li - 1;
    $timestr_starts = 0 if $timestr_starts < 0;

    # Divide text in an array of words, based on spaces
    my @quote_array   = split /\s/, $quote;
    my @timestr_array = split /\s/, $timestr;

    my @word_pieces;
    for my $i (0 .. @quote_array - 1) {
        my $word = $quote_array[$i];

        # Change the look of the text if it is part of the time string
        my @pieces = ();
        if ( $i >= $timestr_starts and $i < ($timestr_starts + @timestr_array) ) {
            # This word has part of the timestr in it, we need to highlight some of it
            my $time_word = $timestr_array[$i - $timestr_starts];

            my ($pre, $hi, $post) = $word =~ m{\A (.*?) (\Q$time_word\E) (.*) \z}xi
                or die "Unable to find '$time_word' in '$word'";

            push @pieces, [$font_path,      "grey",  $pre       ] if $pre;
            push @pieces, [$font_path_bold, "black", $hi        ];
            push @pieces, [$font_path,      "grey",  $post . " "];
        }
        else {
            # Normal word, no part of the timestr is in it
            push @pieces, [$font_path, "grey", $word . " "];
        }

        push @word_pieces, \@pieces;
    }

    return \@word_pieces;
}

sub fit_text {
    my ($word_pieces, $font_size) = @_;

    # Track the x and y position of words
    my ($pos_x, $pos_y) = ($margin, $margin+$font_size);

    # Work out the farthest we can go down the page
    # We need to leave space for the margin and two rows of text
    my (undef, $textheight) = measureSizeOfTextbox($creditFont_size, $creditFont, "M");
    my $max_y = $height - $margin - $textheight*1.1 - $textheight;

    foreach my $wp (@$word_pieces) {
        # Measure the word's width
        my $wordwidth = 0;
        foreach my $p (@$wp) {
            my ($font, $textcolor, $word) = @$p;
            my ($w) = measureSizeOfTextbox($font_size, $font, $word);

            $wordwidth += $w;
        }

        ## Write every word to image, and record its position for the next word

        # If one word exceeds the width of the image (which can happen when the quote is very short),
        # then stop trying to make the font size even bigger.
        if ( $wordwidth > ($width - $margin) ) {
            return;
        }

        # If the line plus the extra word is too wide for the specified width, then write
        # the word on the next line.
        if ( ($pos_x + $wordwidth) >= ($width - $margin) ) {
            # 'carriage return': Reset x to the beginning of the line and push y down a line
            $pos_x  = $margin;
            $pos_y += int($font_size*1.618 + 0.5); # 'golden ratio' line height

            if ($pos_y >= $max_y) {
                # This call to fit_text returned a paragraph that is in fact higher than the height
                # of the image, return without those values to indicate we went too far
                return;
            }
        }

        # Add the word's width
        $pos_x += $wordwidth;
    }

    return ($pos_y, $font_size);
}

sub draw_text {
    my ($word_pieces, $font_size) = @_;

    # Create image
    my $img = GD::Image->new($width, $height)
        or die "Cannot create new GD::Image";

    # Define the colors
    my %color =
        (bg    => $img->colorAllocate(255, 255, 255),
         grey  => $img->colorAllocate(125, 125, 125),
         black => $img->colorAllocate(  0,   0,   0),
        );

    # variable to hold the x and y position of words
    my ($pos_x, $pos_y) = ($margin, $margin+$font_size);

    foreach my $wp (@$word_pieces) {
        # Measure the word's width
        my @widths;
        my $wordwidth = 0;
        foreach my $p (@$wp) {
            my ($font, $textcolor, $word) = @$p;
            my ($w) = measureSizeOfTextbox($font_size, $font, $word);

            $wordwidth += $w;
            push @widths, $w;
        }

        # If the line plus the extra word is too wide for the specified width, then write
        # the word on the next line.
        if ( ($pos_x + $wordwidth) >= ($width - $margin) ) {
            # 'carriage return': Reset x to the beginning of the line and push y down a line
            $pos_x  = $margin;
            $pos_y += int($font_size*1.618 + 0.5); # 'golden ratio' line height

        }

        # Write the word to the image
        my $i = 0;
        foreach my $p (@$wp) {
            my ($font, $textcolor, $word) = @$p;
            my $color = $color{$textcolor}
                // die "No color for '$textcolor'";
            $img->stringFT($color, $font, $font_size, 0, $pos_x, $pos_y, $word);

            # Add the word's width
            $pos_x += $widths[$i++];
        }
    }

    return ($img);
}

sub measureSizeOfTextbox {
    my ($font_size, $font_path, $text) = @_;

    return dimensions( GD::Image->stringFT(1, $font_path, $font_size, 0, 0, 0, $text) );
}

sub dimensions {
    #   llx     lly     lrx     lry    urx    ury
    my ($min_x, $max_y, $max_x, undef, undef, $min_y) = @_;

    my $width  = ( $max_x - $min_x );
    my $height = ( $max_y - $min_y );
    my $left   = abs( $min_x ) + $width;
    my $top    = abs( $min_y ) + $height;

    return($width, $height, $left, $top);
}

sub add_source {
    my ($img, $title, $author) = @_;

    # Define colors
    my $grey_c  = $img->colorExact(125, 125, 125);
    my $black_c = $img->colorExact(  0,   0,   0);

    my $em_dash = "—";

    my $credits = $title . ", " . $author;

    # If the metadata is longer than 45 characters, replace a space by a newline from the end,
    # just as long the as paragraph is getting smaller.
    # Stop when the box gets wider again.
    my ($metawidth, undef, $metaleft, undef) =
        measureSizeOfTextbox($creditFont_size, $creditFont, $em_dash . $credits);

    if ( $metawidth > 500 ) {
        my @newCredits = ($credits, "");

        my @line1 = split /\s/, $credits;
        my @line2;
        my $i = 1;
      CUT_LOOP:
        while (1) {
            unshift @line2, pop @line1;

            my $tmp0 = join(" ", @line1);
            my $tmp1 = join(" ", @line2);

            # Once the second line is (almost) longer than the first line, stop
            if ( length($tmp1)+5 > length($tmp0) ) {
                last CUT_LOOP;
            } else {
                # If the second line is still shorter than the first, save it to a new string,
                # but continue to look for a new fit.
                $newCredits[0] = $tmp0;
                $newCredits[1] = $tmp1;
            }

            $i++;
        }

        my ($textWidth1, $textheight1) =
            measureSizeOfTextbox($creditFont_size, $creditFont, $em_dash . $newCredits[0]);
        my ($textWidth2) =
            measureSizeOfTextbox($creditFont_size, $creditFont, $newCredits[1]);

        my $metadataX1 = $width-($textWidth1+$margin);
        my $metadataX2 = $width-($textWidth2+$margin);
        my $metadataY  = $height-$margin;

        $img->stringFT($black_c, $creditFont, $creditFont_size, 0,
                       $metadataX1, $metadataY-($textheight1*1.1), $em_dash . $newCredits[0]);
        $img->stringFT($black_c, $creditFont, $creditFont_size, 0,
                       $metadataX2, $metadataY, $newCredits[1]);

    } else {
        # Position of single line metadata
        my $metadataX = ($width-$metaleft)-$margin;
        my $metadataY = $height-$margin;

        $img->stringFT($black_c, $creditFont, $creditFont_size, 0,
                       $metadataX, $metadataY, $em_dash . $credits);
    }
}

sub colorimg_to_grey {
    my ($file) = @_;

    # Convert the image we made to greyscale
    state $im = Image::Magick->new(magick => 'png');

    # Define the image you want to convert
    $im->Read($file);

    # Set grayscale
    $im->Quantize(colorspace=>'gray');

    # Write the new file
    unlink($file);

    # Write the last image in the sequence if there are multiple
    # Quality is defined here -- http://imagemagick.org/script/command-line-options.php#quality
    $im->[-1]->Write(filename => $file, quality => '92');

    return;
}

sub get_num_tasks {
    # No args

    my $info = Sys::Info->new;
    my $cpu  = $info->device('CPU');

    return $cpu->count();
}

sub DEBUG_MSG {
    my @dump = @_;

    my ($package, $filename, $line) = caller;

    local $Data::Dumper::Indent = 1;
    local $Data::Dumper::Sortkeys = 1;
    local $Data::Dumper::Indent = 1;
    local $Data::Dumper::Sortkeys = 1;
    print STDERR "Debug at $filename:$line:\n", Dumper(@dump);

    return;
}
