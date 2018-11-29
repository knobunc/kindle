package TimeMatch;

use Modern::Perl '2017';

use utf8;

use Exporter::Easy (
  EXPORT => [ qw( do_match extract_times ) ],
);

use Carp;
use Data::Dumper;
use Lingua::EN::Words2Nums;


# Special named times
my $noon_re     = qr{ ( high \s+ )? noon | noonday | mid[-\s]*day | noontime | noontide }xin;
my $midnight_re = qr{ midnight (?! \s+ oil ) }xin;
my $ecclesiastical_re =
    qr{ # Ecclesiastical times -- https://en.wikipedia.org/wiki/Liturgy_of_the_Hours
        # Prime and Nones are handled specially
        matins  | lauds    | terce      | sext
      | vespers | compline | vigils     | nocturns
      | night \s+ office
      | ( dawn | early \s+ morning | mid-morning | mid-?day | mid-afternoon | evening | night )
        \s+ prayer
      }xin;
my $all_ecclesiastical = qr{ $ecclesiastical_re | prime | nones }xin;
my $midnight_noon_re = qr{ $noon_re | $midnight_re | $ecclesiastical_re }xin;

# Numbers 1-9 as words
my $low_num_re = qr{ one | two | three | four | five | six | seven | eight | nine }xi;

# The hours 1-12 as words
my $hour12_word_re = qr{ $low_num_re | ten | eleven | twelve | $midnight_noon_re }xi;
my $hour_word_re   = $hour12_word_re;

# The hours 13-24 as words
my $hour_h_word_re = qr{ thirteen | fourteen | fifteen
                       | sixteen | seventeen | eighteen | nineteen
                       | twenty ( - ( one | two | three | four ) )?
                       }xin;
my $hour24_word_re = qr{ $hour_word_re | $hour_h_word_re }xin;

my $fraction_re = qr{ quarter | 1/4
                    | third   | 1/3
                    | half    | 1/2
                    | third \s+ quarter | three \s+ quarters | 3/4
                    }xin;

my $before_re = qr{ before | to | of | till | ['‘’]til | short \s+ of }xin;
my $after_re  = qr{ after | past }xin;
my $till_re   = qr{ $before_re | $after_re }xin;

# The minutes
my $min_word_re =
    qr{ # 1-9
        ( oh [\s-] | \b )? $low_num_re
        | # 10-19
        ( ten | eleven | twelve | thirteen | fourteen | fifteen |
            sixteen | seventeen | eighteen | nineteen )
        | # 20-59
        ( twenty | thirty | forty | fifty ) ( ( -| \s+ ) $low_num_re )?
      }xin;
my $sec_word_re = $min_word_re;

# Hour digits
my $hour_dig_re     = qr{ [01]?\d | 2[0-4] }xin;       # 0 or 00-24
my $hour0_dig_re    = qr{ [01]?\d | 2[0-4] }xin;       # 00-24
my $hour12_dig_re   = qr{ [1-9] | 1[0-2] }xin;         # 1-12
my $hour24nz_dig_re = qr{ 0?[1-9] | 1\d | 2[0-4] }xin; # 1 or 01-24
my $hour_h_dig_re   = qr{ 1[3-9] | 2[0-4] }xin;        # 13-24
my $hour24_dig_re   = $hour_dig_re;

# Min / sec digits
my $minsec_dig_re  = qr{ [0-5]?\d | 60 }xin;
my $minsec0_dig_re = qr{ [0-5]\d | 60 }xin;

# The minutes / seconds as words or numbers
my $min_re = qr{ $minsec_dig_re | $min_word_re }xin;
my $min0_re = qr{ $minsec0_dig_re | $min_word_re }xin;
my $sec_re = $min_re;

# The hours as words or numbers
my $hour_re   = qr{ $hour24_dig_re | $hour12_word_re }xin;
my $hour12_re = qr{ $hour12_dig_re | $hour12_word_re }xin;
my $hour24_re = qr{ $hour24_dig_re | $hour24_word_re }xin;
my $hour_h_re = qr{ $hour_h_dig_re | $hour_h_word_re }xin; # The high hours 13-24

# The am / pm permutations
my $in_the_re = qr{ ( ( in \s+ the \s+ ( (?! same) \w+ \s+ ){0,4}?
                      | that \s+ ( \w+ \s+ ){0,2}?
                      )
                      ( morning | mornin['‘’]? | morn | afternoon | evening | eve | day | night)
                    | at \s+ ( dawn | dusk | night | sunset | sunrise )
                    )
                  }xin;
my $ampm_only_re = qr{ [ap]m \b | [ap][.] \s* m[.]? | pee \s+ em | $in_the_re }xin;
my $ampm_re = qr{ $ampm_only_re | $in_the_re }xin;

# Oclocks
my $oclock_re = qr{ o( ['‘’´] \s* | f \s+ the \s+ )?clock s? }xin;

# Boundary before and after
my $bb_re = qr{ (?<= [\[—\s"'(‘’“”] ) | \A }xin;
my $ba_re = qr{ \b | (?= [—/"'‘’“”\s.…,:;?] ) | \z }xin;

# Match stuff from the start of the string to here.
# This must have an anchor for the start before it, specifically \G
# and it must be matched and included in the results
# i.e.:  \G ( $not_in_match )
my $not_in_match    = qr{ [—…,:;?/""''‘’“”\s([] | \G [-.]? | [^\d\w] [-.] }xin;

# Relative words
my $far_re          = qr{ well    | long                }xin;
my $short_re        = qr{ shortly | just | a \s+ little }xin;

my $far_before_re   = qr{   $far_re   \s+    before
                        |   far [-\s]+ ( from | off )
                        }xin;
my $short_before_re = qr{   $short_re \s+    before
                        |   nearly
                        |   near ( \s+ on )?
                        |   towards?
                        |   lacks \s+ of
                        |   almost ( \s ( gone | at ) )?
                        |   just \s+ about
                        |   can['‘’]t \s+ be \s+ $far_before_re
                        }xin;
my $around_re       = qr{ about
                        | approximately
                        | around
                        }xin;
my $on_or_after_re  = qr{ ( $short_re \s+ )? gone }xin;
my $far_after_re    = qr{   $far_re   \s+    after      }xin;
my $short_after_re  = qr{ ( $short_re \s+ )? ( after | past )
                        | can['‘’]t \s+ be \s+ $far_after_re
                        }xin;

my $rel_words       = qr{ $far_before_re | $short_before_re
                        | $around_re
                        | $on_or_after_re
                        | $far_after_re  | $short_after_re
                        }xin;

my $at_words     = qr{ until | at | before }xin;
my $rel_at_words = qr{ $at_words | $rel_words }xin;

# Weekdays
my $weekday_re = qr{ monday | tuesday | wendesday | thursday | friday | saturday | sunday }xin;

# Times of day
my $timeday_re = qr{ day | morning | night }xin;

# Bible books
my $bible_book_re = qr{ Acts | Amos | Baruch | [12] \s+ Chronicles | Colossians
                      | [12] \s+ Corinthians | Daniel | Deuteroronomy | Ecclesiastes
                      | Ephesians | Esther | Exodus | Ezekiel | Ezra | Galatians
                      | Genesis | Habakkuk | Haggai | Hebrews | Hosea | Isaiah
                      | James | Jeremiah | Job | Joel | John | [123] \s+ John
                      | Jonah | Joshua | Jude | Judges | Judith | [12] \s+ Kings
                      | Lamentations | Leviticus | Luke | [12] \s+ Maccabees
                      | Malachi | Mark | Matthew | Micah | Nahum | Numbers | Obadiah
                      | [12] \s+ Peter | Philemon | Philippians | Proverbs | Psalms
                      | Revelation | Romans | Ruth | [12] \s+ Samuel | Sirach
                      | Solomon | [12] \s+ Thessalonians | [12] \s+ Timothy
                      | Titus | Tobit | Wisdom | Zechariah | Zephaniah
                      }xin;

# The states, short and long
my $state_re = qr{
                   Alabama            | AL
                 | Alaska             | AK
                 | Arizona            | AZ
                 | Arkansas           | AR
                 | California         | CA
                 | Colorado           | CO
                 | Connecticut        | CT
                 | Delaware           | DE
                 | Florida            | FL
                 | Georgia            | GA
                 | Hawaii             | HI
                 | Idaho              | ID
                 | Illinois           | IL
                 | Indiana            | IN
                 | Iowa               | IA
                 | Kansas             | KS
                 | Kentucky           | KY
                 | Louisiana          | LA
                 | Maine              | ME
                 | Maryland           | MD
                 | Massachusetts      | MA
                 | Michigan           | MI
                 | Minnesota          | MN
                 | Mississippi        | MS
                 | Missouri           | MO
                 | Montana            | MT
                 | Nebraska           | NE
                 | Nevada             | NV
                 | New \s+ Hampshire  | NH | N\. \s* H\.
                 | New \s+ Jersey     | NJ | N\. \s* J\.
                 | New \s+ Mexico     | NM | N\. \s* M\.
                 | New \s+ York       | NY | N\. \s* Y\.
                 | North \s+ Carolina | NC | N\. \s* C\.
                 | North \s+ Dakota   | ND | N\. \s* D\.
                 | Ohio               | OH
                 | Oklahoma           | OK
                 | Oregon             | OR
                 | Pennsylvania       | PA
                 | Rhode \s+ Island   | RI | R\. \s* I\.
                 | South \s+ Carolina | SC | S\. \s* C\.
                 | South \s+ Dakota   | SD | S\. \s* D\.
                 | Tennessee          | TN
                 | Texas              | TX
                 | Utah               | UT
                 | Vermont            | VT
                 | Virginia           | VA
                 | Washington         | WA
                 | West \s+ Virginia  | WV | W\. \s* V\.
                 | Wisconsin          | WI
                 | Wyoming            | WY
                   # Commonwealth and Territories
                 | American \s+ Samoa                         | AS | A\. \s* S\.
                 | District \s+ of \s+ Columbia               | DC | D\. \s* C\.
                 | Federated \s+ States \s+ of \s+ Micronesia | FM
                 | Guam                                       | GU
                 | Marshall \s+ Islands                       | MH | M. \s* I\.
                 | Northern \s+ Mariana \s+ Islands           | MP
                 | Palau                                      | PW
                 | Puerto \s+ Rico                            | PR | P\. \s* R\.
                 | Virgin \s+ Islands                         | VI | V\. \s* I\.
}xin;

# The months
my $month_re = qr{ January | February | March | April | May | June
                 | July | August | September | October | November | December }xin;
my $special_day_re = qr{ Christmas | Easter | New \s+ Year s? }xin;

# Time periods
my $time_periods_re = qr{ ( year | month | week | day | hour | half | minute ) s? }xin;

# Things that never follow times
my $never_follow_times_re =
    qr{ ( or \s+ $min_re )?
        ( with | which | point | time | moment | instant | end | stage | of | who
        | after | since
        | degrees
        | centimeter | cm | meter | kilometer | km | klick
        | inch | inches | foot | feet | ft | yard | yd | mile | mi
        | cubic | square
        | hundred | thousand | million | billion
        | ( \w+ \s+)? $time_periods_re
        | third | half | halve | quarter
        | dollar | cent | pound | shilling | guinea | penny | pennies | yuan | galleon | crown
        | and \s+ sixpence
        | kid | children | man | men | woman | women | girl | boy
        | family | families | person | people
        | round | turn   | line
        | book  | volume | plate | illustration | page
        | side  | edge   | corner | face
        | Minister
        | possibilities  | against | vote | machine | box
        | on \s+ the \s+ field
        )
        s?
      }xin;

# Set the branch state variable
my $branch = "x";

sub do_match {
    my ($line) = @_;

    #$line =~ s{ ( $not_in_match*? ) ((just)?) }{[$1]>$2<}gxi;
    #return $line;

    ## Shortcircuit if it just has a number in the line
    # e.g "Twenty-one" since these are probably chapters
    if ($line =~ m{ \A [\n\s]* $min_word_re ( [-\s]+ $low_num_re )? [\n\s]* \z }xin) {
        return $line;
    }

    ## Does this look like a "timey" paragraph
    my $is_timey = 0;
    $is_timey = 1
        if $line =~
            m{ \b (struck   |
                   hour     |
                   minute   |
                   clock    |
                   watch    |
                   $midnight_noon_re |
                   train |
                   what \s+ time |
                   ( there | here ) \s+ from |
                   ( return | returned | back ) \s* $rel_at_words |
                   reported
                   ) \b
             }xin;

    ## Mask out some patterns and apply them first
    my ($masks) = get_masks();

    ## Get the matches and apply them
    my ($r) = get_matches();

    my @parts = $line;
    foreach my $r (@$masks, @$r) {
        my @new;
        foreach my $part (@parts) {
            if ($part !~ m{<<}) {
                while ($part ne '') {
                    if ($part =~ m{$r}p) {
                        my $match =
                            sprintf("%s<<%s%s|%s>>%s",
                                    map { defined ? $_ : "" }
                                    $+{pr}, $+{t1}, $+{t2}, $branch, $+{po});
                        my ($leadin, $leadout) = map { defined ? $_ : "" } ($+{li}, $+{lo});

                        push @new, ${^PREMATCH} . $leadin, $match;
                        $part = $leadout . ${^POSTMATCH};
                    }
                    else {
                        push @new, $part;
                        $part = '';
                    }
                }
            }
            else {
                push @new, $part;
            }
        }
        @parts = @new;
    }
    $line = join '', @parts;

    ## Fixups
    # Change TIMEY to $is_timey's value
    $line =~ s{<< ([^|>]+) [|] (\d+ \w?) :TIMEY >>}{<<$1|$2:$is_timey>>}xg;

    # Get absolute words out
    $line =~ s{<< ( ( at | by ) \s )}{$1<<}xgi;

    # Undo the masks
    $line =~ s{<< ( [^>]+ ) \| [yx]\d+\w? >>}{$1}xgi;

    return $line;
}

sub get_masks {
    state @r;
    return(\@r)
        if @r;

    # Take out compound numbers, times never look like:
    # 12,000
    # 14.000
    push @r,qr{ $bb_re
                (?<t1> ( \d{1,3} ( [,] \d{3} )+
                       | \d{1,3} ( [.] \d{3} )+
                       )
                )
                $ba_re
                (?{ $branch = "x1"; })
              }xin;

    # odds of five to one
    push @r,qr{ $bb_re
                (?<pr>
                 ( ( odds | betting ) \s+ ( of | being | at ) ( $rel_words \s+ )?
                   | got | get | numbers?
                 ) \s+
                )
                (?<t1> $min_re \s+ to \s+ $min_re )
                (?! ,? \s* $ampm_re)
                \b
                (?{ $branch = "x2"; })
              }xin;

    # one's
    push @r,qr{ (?<t1> \b one ['‘’] s \b )
                (?{ $branch = "x3"; })
              }xin;

    # I was one of twenty
    push @r,qr{ (?<pr> \s+ )
                (?<t1> one \s+ of \s+ $min_re )
                (?! ,? \s* $ampm_re)
                \b
                (?{ $branch = "x4"; })
              }xin;

    # Bible quotes
    push @r,qr{ (?<pr> $bible_book_re ,? \s+ )
                (?<t1>
                     \d+ : \d+ ( - \d+ | - \d+ : \d+ )?
                | \( \d+ : \d+ ( - \d+ | - \d+ : \d+ )? \)
                | \[ \d+ : \d+ ( - \d+ | - \d+ : \d+ )? \]
                )
                (?{ $branch = "x5"; })
              }xin;

    # age of twenty-four, aged twenty-four
    push @r,qr{ (?<pr> \s+ ( age \s+ of | aged )\s+ )
                (?<t1>
                  $min_word_re ( [-\s]+ $low_num_re )?
                  ( \s+ ( or | to ) \s
                   $min_word_re ( [-\s]+ $low_num_re )?
                  )?
                )
                \b
                (?{ $branch = "x6"; })
              }xin;

    # months or special days followed by years
    push @r,qr{ (?<pr> ( $month_re | $special_day_re )[,]? \s+ )
                (?<t1> \d{4} )
                (?! ,? \s* $ampm_re)
                \b
                (?{ $branch = "x7"; })
              }xin;

    # AD or BC or BCE
    my $bcad_re = qr{ BC | BCE | B\.C\. | AD | A\.D\. }xin;
    push @r,qr{ (?<t1>
                  ( \b $bcad_re \s* \d+
                  | \b \d+ \s* $bcad_re
                  )
                )
                $ba_re
                (?{ $branch = "x8"; })
              }xin;

    # Addresses
    push @r,qr{ (?<t1>
                  \b \d+ \s* ( \w | \# \d+ )? \s+
                  ( \w+ \s+ )?
                  ( road | rd
                  | street | st
                  | avenue | ave
                  | crescent
                  | boulevard | blvd | bvd
                  )
                )
                $ba_re
                (?{ $branch = "x9"; })
              }xin;

    # Zip codes
    push @r,qr{ (?<t1>
                  \b $state_re [.,\s]+
                  \d{5}
                )
                $ba_re
                (?{ $branch = "x10"; })
              }xin;

    # Things that look like times but have high hours
    # Eighteen to twenty
    push @r,qr{ (?<li> $not_in_match )
                (?<t1> $min_word_re \s+ to \s+ $hour_h_re )
                $ba_re
                (?! \s+ to )
                (?{ $branch = "x11"})
              }xin;

    # Page numbers
    push @r,qr{ (?<li> $not_in_match )
                (?<t1> pp?\. \s+ \d+ )
                $ba_re
                (?{ $branch = "x12"})
              }xin;

    # Dates
    push @r,qr{ (?<li> $not_in_match )
                (?<t1> \d\d? \. \d\d? \. \d\d? )
                $ba_re
                (?{ $branch = "x13"})
              }xin;

    return(\@r);
}

sub get_matches {
    state @r;
    return(\@r)
        if @r;

    # Capture names:
    # li - Lead-in: Stuff before the match that we don't mask out
    # pr - Preamble: Stuff that is part of the match phrase but not the time
    # t1 - Time 1: The time phrase
    # t2 - Time 2: More of the time phrase (if needed)
    # po - Postamble: Part of the match phrase but not the time
    # lo - Lead-out: Stuff after the match that we don't mask out

    # Times to/from hour
    # ten minutes past noon
    # three minutes till eight
    my $nf_re = qr{(?! \s+ $never_follow_times_re
                     | :\d
                     | [-]
                     )
                  }xin;
    push @r,qr{ (?<li> $not_in_match )
                (?<t1>
                  ( ( $rel_words \s+
                    | between \s+ $min_word_re \s+ and \s+
                    | $min_word_re \s+ or \s+
                    )?
                    ( $min_word_re | \d{1,2} | a | a \s+ few ) ( \s+ | [-] )
                    ( minute s? \s+ )?
                    ( and ( \s+ | [-] )
                            ( a \s+ half | 1/2 | a \s+ quarter | 1/4 | twenty
                            | $sec_re \s+ second s?
                            )? \s+
                    | ( after | before ) \s+ ( the \s+ )? $fraction_re ( \s+ | [-] )
                    )?
                    ( minute s? \s+ )?
                  | ( $rel_words \s+ ( a \s+ )? )? $fraction_re ( \s+ | [-] )
                  | ( just | nearly ) \s+
                  | in \s+ ( $rel_words \s+ )? $min_word_re \s+ ( minute s? \s+ )?
                    it \s+ (would | will) \s+ be \s+ (a \s+)?
                    $fraction_re ( \s+ | [-] )
                  )
                  $till_re [-—\s]+
                  ( the \s+ hour [,;]? \s+ which \s+ was \s+ )?
                  $hour24_re
                  ( \s+ $oclock_re ( ,? \s* $ampm_re )?
                  |                  ,? \s* $ampm_re
                  | $nf_re
                  )
                )
                $ba_re
                (?{ # This is a bit tricky
                    # Basically we are deciding if the match is of the form 'five to ten' and
                    # if so, we change the branch
                    $branch = "10";

                    my $t1 = $+{t1};
                    my $pre = ${^PREMATCH} . $+{li};
                    my $post = ${^POSTMATCH};

                    if ($t1 =~ m{\A $min_word_re [-\s]+ to [-\s]+ $hour24_re \z}xin) {
                        $branch = "10a:TIMEY";
                        if ($pre =~ m{ \s of \s+ \z}xin) {
                            $branch = "y10";
                        }
                        elsif ($pre =~ m{ (\A | \s )
                                          ( at | it \s+ ( is | was ) | twas | it['‘’]?s | till )
                                          \s+ \z
                                        }xin)
                        {
                            $branch = "10";
                        }
                    }
                  })
              }xinp;
    # TODO Do we need to skip nine-to-five?

    # Ones with a phrase before to fix it better as a time
    push @r,qr{ \b (?<pr> ( meet  | meeting  | meets
                      |  start | starting | starts
                     ) \s+
                     ( ( tonight | today | to-?morrow | $weekday_re | this ) \s+
                      ( ( morning | afternoon | evening ) \s+ )?
                     )?
                     at \s+
                   )
                   (?<t1> ( $rel_words \s+ )?
                     $hour24_re ( [-.:\s]* $min0_re )?
                     (?! \s+ $never_follow_times_re \b )
                     ( ,? \s* $ampm_re )?
                   )
                   $ba_re
                (?{ $branch = "9g"})
              }xin;

    # after eleven the next day
    push @r,qr{ \b (?<t1> ( $rel_words | ( close \s+ )? upon ) \s+
                     ( \w+ \s+ )?
                     $hour_word_re
                   )
                    ( (?<t2> \s+ $in_the_re ) \b
                    | (?<t2> ,? \s* $ampm_re )
                    | (?<po>
                        \s+ the  \s+ ( next | following ) \s+ $timeday_re
                      | \s+ for  \s+ ( breakfast | lunch | dinner | luncheon | tea )
                      | \s+ on   \s+ ( the \s+ )? $weekday_re
                      | \s+ that \s+ $timeday_re
                      | \s+ ( tonight | today | to-?morrow )
                      )
                   )
                   $ba_re
                 (?{ $branch = "9h"})
              }xin;

    # Ones with a phrase after to fix it better as a time
    push @r,qr{ \b (?<pr> ( at | it \s+ ( is | was ) | twas | it['‘’]?s | till ) \s+ )
                   (?<t1> ( ( $rel_words ( \s+ at )? | ( close \s+ )? upon ) \s+ )?
                     $hour_word_re
                   )
                   ( (?<t2> \s+ $in_the_re ) \b
                   | (?<po>
                        \s+ the  \s+ ( next | following ) \s+ $timeday_re
                      | \s+ for  \s+ ( breakfast | lunch | dinner | luncheon | tea )
                      | \s+ on   \s+ ( the \s+ )? $weekday_re
                      | \s+ that \s+ $timeday_re
                      | \s+ ( tonight | today | to-?morrow )
                      )
                   ) $ba_re
                   (?{ $branch = "9a"; })
              }xin;

    # ... meet me ... at ten forty-five.
    push @r,qr{ $bb_re
                (?<li> meet \s+ me \b [^.!?]* \s+ at \s+
                |      start \s+ by \s+ ( the \s+ )?
                )
                (?<t1> $hour24_re [-\s.]+ $min_re ( ,? \s* $ampm_re )? )
                $ba_re
                (?{ $branch = "5c"})
              }xin;
    # here at seven thirty, be at six forty-five
    push @r,qr{ $bb_re
                (?<pr> ( here | be ) \s+ at \s+ )
                (?<t1> $hour24_re [-\s.]+ $min_word_re ( ,? \s* $ampm_re )?)
                $ba_re
                (?{ $branch = "5e"})
              }xin;

    # Due ... at eleven-fifty-one
    # Knocks ... at 2336
    push @r,qr{ $bb_re
                (?<pr> ( due | knocks ) \s+ [\w\s]* at \s+ )
                (?<t1> $hour24_re [-\s.:]* $min_re ( ,? \s* $ampm_re )?)
                $ba_re
                (?{ $branch = "5d"})
              }xin;

    # on the 1237
    push @r,qr{ (?<li> $not_in_match )
                (?<pr> ( on \s+ the
                       |  here \s+ at
                       ) \s+
                )
                (?<t1> ( $hour12_dig_re [.]? | $hour24_dig_re [.] )
                       $minsec0_dig_re
                )
                $ba_re
                (?{ $branch = "3c"})
              }xin;

    # 13 hours and 6 minutes
    # 13 hours, 6 minutes, and 10 seconds
    push @r,qr{ $bb_re
                (?<t1>
                        $hour24_re \s+ ( hour | $oclock_re | h | hr ) s? ,? ( \s+ and )?
                    \s+ $min_re    \s+ ( minute | min | m )           s?
                    ( ,? \s* $ampm_re )?
                )
                (?<po>
                  ,? ( \s+ and )?
                  ( \s+ $sec_re    \s+ ( seconds | sec | s)           s?
                   | ( \s+ a )? \s+ $fraction_re
                  )?
                  (?! [-\s]+ $never_follow_times_re \b )
                )
                $ba_re
                (?{ $branch = "14"})
               }xin;

    # O'Clocks
    # 1 o'clock, 1 oclock, 1 of the clock
    push @r,qr{ (?<li> $not_in_match )
                (?<t1>
                  ( $rel_words \s+ )?
                  $hour24_re [?]? ( [-.:] $min_re )?
                  [-\s]+ $oclock_re
                  ( ,? \s* $ampm_re )?
                  ( ,? \s+ all \s+ but \s+ $min_re (\s+ minutes?)? )?
                )
                $ba_re
                (?{ $branch = "6"})
              }xin;

    # Times at the end of a phrase
    # These are guaranteed times:
    #   waited until eight, ...
    push @r,qr{ $bb_re
                (?<pr>
                  ( waited | arrive s? | called | expired
                  | only | it \s+ ( is | was ) | twas | it['‘’]?s | begin | end | it
                  | ( come | turn ) \s+ on
                  ) \s+
                  ( ( exactly | precisely ) \s+ )?
                  ( ( at | upon | till | until ) \s+ )?
                )
                (?<t1> ( $rel_words \s+ )?
                  $hour12_re ( ( [-:.] | \s+ )? $min0_re )?
                )
                (?<po>
                  ( \z | [.…;:?!,]? ['"‘’“”] | [.…;:?!,] ( \s+ | \z ) | \s+ [-—]+ \s+)
                | \s+ ( and | [-—] ) \s+
                )
                (?{ $branch = "9f"})
              }xin;

    # Simple times
    # 2300h, 23.00h, 2300 hrs
    my $lnr = qr{ $low_num_re | zero | oh }xin;
    push @r,qr{ $bb_re
                (?<t1> ( $rel_words \s+ )?
                  ( $hour_dig_re [.:]? $minsec_dig_re
                    ( [.:]? $minsec_dig_re ( - $minsec_dig_re )? )?
                  | ( $lnr \s+ ){3} $lnr
                  )
                  ( h | \s* ( hrs | hours ) )
                )
                $ba_re
                (?{ $branch = "1"})
              }xin;

    # 2300 GMT, 2300z
    # Sounded out digits
    #  zero eight zero zero
    #  oh eight oh oh
    push @r,qr{ $bb_re
                (?<t1> ( $rel_words \s+ )?
                 ( $hour_dig_re [.:]? $minsec0_dig_re )
                )
                (?<po> ( [.:]? $minsec_dig_re ( - $minsec_dig_re )? )?
                  ( z | \s* ( gmt | zulu ) )
                )
                $ba_re
                (?{ $branch = "1a"})
              }xin;
    # 11h20
    push @r,qr{ $bb_re
                (?<t1>
                 ( $rel_words \s+ )?
                  $hour_dig_re h $minsec0_dig_re m?
                )
                $ba_re
                (?{ $branch = "1b"})
              }xin;

    # Separators are mandatory, and it needs am/pm
    # 5.06 a.m.
    push @r,qr{ (?<li> $not_in_match )
                (?<t1>
                  ( $rel_words \s+ )?
                  $hour12_dig_re [.:] $minsec_dig_re
                )
                ( (?<t2> ,? \s* $ampm_re )
                | (?<po> ( [.:] $minsec_dig_re )? ,? \s* $ampm_re )
                )
                (?{ $branch = "2a"})
              }xin;

    # : Means it's a time
    # 12:37
    push @r,qr{ (?<li> $not_in_match )
                (?<t1>
                 ( $rel_words \s+ )?
                 $hour_dig_re : $minsec0_dig_re
                )
                ( (?<t2> ,? \s* $ampm_re )
                | (?<po> ( : $minsec_dig_re )?
                  ,? \s* $ampm_re )
                )?
                $ba_re
                (?{ $branch = "2"})
              }xin;

    # one hour and a quarter
    push @r,qr{ $bb_re
                (?<t1> $hour24_re \s+ hour s? ,? \s+ and \s+
                  a \s+ $fraction_re
                )
                $ba_re
                (?{ $branch = "14a:TIMEY"})
               }xin;

    # Word times (other word times come later)
    # eleven fifty-six am
    # three in the morning
    # 1 pm, one p.m.
    push @r,qr{ (?<li> $not_in_match )
                (?<t1> ( $rel_words \s+ )?
                  $hour_re
                  ( [-\s.]+ $min_word_re )?
                  ( [-\s.]+ $sec_word_re )?
                  ,? \s* $ampm_re
                )
                $ba_re
                (?{ $branch = "5"})
              }xin;

    # at 1237 when
    # by 8.45 on saturday
    push @r,qr{ (?<li> $not_in_match )
                (?<pr> ( at | it \s+ ( is | was ) | twas | it['‘’]?s | by | by \s+ the ) \s+ )
                (?<t1> $hour_re [?]? [-.\s]? $min_re )
                (?<po>
                 \s+ ( ( ( on | in ) \s+ )? $weekday_re
                       | when
                       | today | tonight | to-?morrow
                       | ( this | that | one | on \s+ the ) \s+
                         ( morning | morn | afternoon | evening | night )
                       )
                )
                $ba_re
                (?{ $branch = "3b"})
              }xin;
    # Three in the morning
    push @r,qr{ (?<li> $not_in_match )
                (?<pr> ( at | it \s+ ( is | was ) | twas | it['‘’]?s | by | by \s+ the ) \s+ )
                (?<t1> $hour_re [?]? [-.\s]? $min_re
                  \s+ in
                  \s+ ( the \s+ ( morn | morning | afternoon | evening ) )
                )
                $ba_re
                (?{ $branch = "3d"})
              }xin;

    # Four, ...
    push @r,qr{ (?<pr> \A | ['"‘’“”] | [.…;:?!] \s+ )
                (?<t1> $hour_word_re )
                (?<po> [,] \s+ )
                (?{ $branch = "9i:TIMEY" })
              }xin;

    # The only time in a sentence
    # See also 9l, 9p, and 9k
    push @r,qr{ (?<pr>
                  ( \A | ['"‘’“”] | [.…;:?!] \s+ | \s+ [-—]+ \s+ )
                  ( ( only | just | it['‘’]?s | it \s+ is | the ) \s+ )?
                )
                (?<t1>
                  ( $rel_words \s+ )?
                  $hour24_word_re ( \s+ | [-] ) $min_word_re ( ,? \s* $ampm_re )?
                )
                (?<po>
                  ( [-] $minsec_dig_re )?
                  ( \s+ ( now | precisely | exactly ) )?
                  ( \z | [.…;:?!,]? ['"‘’“”] | [.…;:?!,] ( \s+ | \z ) | \s+ [-—]+ \s+) )
                (?{ $branch = "9j"})
              }xin;
    # Handle the 6.15 differently so the - doesn't require spaces around it
    # And so that the leading puctuation can be adjacent
    push @r,qr{ (?<pr>
                  ( \A | ['"‘’“”] | [.…;:?!] \s* | \s* [-—]+ \s* )
                  ( ( only | just | it['‘’]?s | it \s+ is | the ) \s+ )?
                )
                (?<t1>
                  ( $rel_words \s+ )?
                  $hour_dig_re [.:] $minsec0_dig_re ( [.:] $minsec0_dig_re )?
                  ( - $minsec0_dig_re )?
                )
                (?<po>
                  ( [-] $minsec_dig_re )?
                  ( \s+ ( now | precisely | exactly ) )?
                  ( \z | [.…;:?!,]? ['"‘’“”] | [.…;:?!,] ( \s+ | \z ) | \s* [-—]+ \s*) )
                (?{ $branch = "9p"})
              }xin;
    # The only time, but as digits with no separators... but often comes up as years
    push @r,qr{ (?<pr>
                  ( \A | ['"‘’“”] | [.…;:?!] \s+ | \s+ [-—]+ \s+ )
                  ( ( only | just | it['‘’]?s | it \s+ is | the ) \s+ )?
                )
                (?<t1>
                  ( $rel_words \s+ )?
                  $hour_dig_re $minsec0_dig_re ( $minsec0_dig_re )?
                )
                (?<po>
                  ( [-] $minsec_dig_re )?
                  ( \s+ ( now | precisely | exactly ) )?
                  ( \z | [.…;:?!,]? ['"‘’“”] | [.…;:?!,] ( \s+ | \z ) | \s+ [-—]+ \s+) )
                (?{ $branch = "9l:TIMEY"})
              }xin;

    # Times at the start of a sentence
    # At ten, ...
    push @r,qr{ (?<pr>
                  ( \A | ['"‘’“”] | [.…;:?!,] \s+ )
                  ( ( it \s+ ( is | was ) | twas | it['‘’]?s | which \s+ was | and ) \s+ )?
                )
                (?<t1>
                  ( $rel_at_words | ( close \s+ )? upon | till | by ) \s+
                  $hour24_re ( [.\s]+ $min0_re )?
                  (?= \s+ ( last | yesterday | $weekday_re ) | \s* [-—,] \s+ )
                )
                $ba_re
                (?{ $branch = "9e"})
              }xin;
    push @r,qr{ (?<pr>
                  ( \A | ['"‘’“”] | [.…;:?!] \s+ )
                  ( it \s+ ( is | was ) | twas | it['‘’]?s ) \s+
                )
                (?<t1>
                  $hour_re ( [-:.] | \s+ )? $min0_re
                | $low_num_re \s* (*SKIP)(*FAIL)
                | $hour_re
                )
                ( [-\s]+ $never_follow_times_re \b (*SKIP)(*FAIL) )?
                $ba_re
                (?{ $branch = "9d"})
              }xin;
    push @r,qr{ (?<pr>
                  ( \A | ['"‘’“”] | [.…;:?!] \s+ )
                  ( at ) \s+
                )
                (?<t1> $hour_re ( ( [-:.] | \s+ )? $min0_re )? ( ,? \s* $ampm_re )? )
                ( [-\s]+ $never_follow_times_re \b (*SKIP)(*FAIL) )?
                $ba_re
                (?{ $branch = "9m"})
              }xin;

    # Strong word times
    # at eleven fifty-seven
    push @r,qr{ (?<li> $not_in_match )
                (?<pr>
                  ( at | ( it | time ) \s+ ( is | was | will \s+ be ) | by
                  | ['‘’] ( twill \s+ be | twas )
                  ) \s+
                )
                (?<t1>
                  $hour24_word_re ( [\s\.]+ | [-] ) $min_word_re
                  ( \s* ... \s* $low_num_re )? ( ,? \s* $ampm_re )?
                )
                ( [-\s]* $never_follow_times_re \b (*SKIP)(*FAIL) )?
                $ba_re
                (?{ $branch = "5b"})
              }xin;

    # In about twenty-eight minutes it will be midnight.
    push @r,qr{ (?<li> $not_in_match )
                (?<t1>
                  in \s+ ( $rel_words \s+ )? $min_re \s+ ( minutes? \s+ )?
                  it \s+ (would | will) \s+ be \s+ (a \s+)?
                  $hour24_word_re ( ( [\s\.]+ | [-] ) $min_word_re )?
                  ( \s* ... \s* $low_num_re )?
                  ( ,? \s* $ampm_re )?
                  ( \s+ $oclock_re )?
                )
                ( [-\s]* $never_follow_times_re \b (*SKIP)(*FAIL) )?
                $ba_re
                (?{ $branch = "5i"})
              }xin;

    # Other weird cases
    # here at nine ...
    push @r,qr{ (?<pr> \b
                  ( here | there
                   | today | tonight | night | to-?morrow
                   | gets \s+ up | woke | rose | waking
                   | happened \s+ at
                   | news ) \s+
                )
                (?<t1> $rel_at_words \s+
                  $hour_word_re
                )
                (?! \s+ $time_periods_re )
                $ba_re
                (?{ $branch = "9b"})
               }xin;

    # at a four-thirty screening
    push @r,qr{ (?<li> $not_in_match )
                (?<pr> ( at \s+ a ) \s+ )
                (?<t1> $hour24_word_re ( \s+ | [-.] ) $min_word_re ( ,? \s* $ampm_re )? )
                (?<po> \s+
                  ( screening | viewing | performance | departure | arrival
                  | game | play | movie | flight | train | ship
                  )
                )
                $ba_re
                (?{ $branch = "5f"})
              }xin;

    # Struck / strikes
    push @r,qr{ \b
                (?<t1>
                  $min_re \s+ minutes \s+ ( before | after ) \s+ the \s+
                  ( clock | bell | watch | it | now | hands ) s? \s+
                  ( struck | strikes | striking | strike | striketh
                  | beat    | beats   | beating
                  | said    | says    | showed | shows
                  | read    | reads   | reading
                  | ( point | pointed | pointing ) \s+ to
                  ) \s+
                  $hour24_re ( [-.\s]+ $min0_re )?
                )
                $ba_re
                (?{ $branch = "11a"})
              }xin;
    push @r,qr{ \b
                (?<pr>
                  ( clock | bell | watch | it | now | hands ) s? \s+ [\w\s]*?
                  ( struck | strikes | striking | strike | striketh
                  | beat    | beats   | beating
                  | said    | says    | showed | shows
                  | read    | reads   | reading
                  | drew
                  | ( point | pointed | pointing ) \s+ to
                  ) \s+
                )
                (?<t1>
                  ( ( a | $min_re ) \s+ minute s? \s+
                    ( before | after | short \s+ of | near \s+ to ) \s+
                  | near \s+ to \s+
                  )?
                  $hour24_re ( [-.\s]+ $min0_re )?
                )
                (?! \s+ ( faces | another ) )
                $ba_re
                (?{ $branch = "11"})
              }xin;
    push @r,qr{ \b
                (?<pr> stroke \s+ of \s+ )
                (?<t1> $hour24_re ( [-.\s]+ $min0_re )? )
                $ba_re
                (?{ $branch = "12"})
              }xin;

    # Noon / midnight
    push @r,qr{ (?<li> $not_in_match )
                (?<t1>
                  ( ( in \s+ ( $rel_words \s+ )? $min_re \s+ ( minutes? \s+ )?
                      it \s+ (would | will) \s+ be \s+ (a \s+)?
                    )
                  | ( $rel_words \s+ )
                  )?
                  $midnight_noon_re
                )
                ( [-\s]+ $never_follow_times_re \b (*SKIP)(*FAIL) )?
                $ba_re
                (?{ $branch = "13"})
              }xin;

    # More at the end of a phrase
    # ... tomorrow at one.
    # ... to-morrow, at ten.
    # ... monday, at twelve.
    push @r,qr{ $bb_re
                (?<pr>
                  ( tonight | today | to-?morrow | $weekday_re | comes ) ,? \s+
                  ( in | at ) \s+
                )
                (?<t1>
                  ( $rel_words \s+ )?
                  ( near \s+ ( on \s+ )? )?
                  $hour_re ( ( [-:.] | \s+ )? $min0_re )?
                )
                (?! [''‘’]s )
                ( [-\s]* $never_follow_times_re \b (*SKIP)(*FAIL) )?
                (?<po>
                  ( \s+ or \s+ so )?
                  ( [""''‘’“”]
                   | [.…;:?!,] ( [""''‘’“”\s] | \z )
                   | \s+ ( and | till | before | [-—] ) \s+
                  )
                )
                (?{ $branch = "9o"})
              }xin;

    push @r,qr{ (?<pr>
                  ( \A | ['"‘’“”] | [.…;:?!,] \s+ )
                  ( ( only | it \s+ ( is | was ) | twas | it['‘’]?s | because ) \s+)?
                )
                (?<t1>
                  ( $rel_at_words | ( close \s+ )? upon | till | by ) \s+
                  ( $hour24_re ( [-:.] | \s+ )? $min0_re
                  | One \s* (*SKIP)(*FAIL)
                  | $hour24_re
                  )
                )
                ( [-\s]* $never_follow_times_re \b (*SKIP)(*FAIL) )?
                $ba_re
                (?{ $branch = "9:TIMEY"})
              }xin;

    # More at the end of a phrase
    # These are not always, so look for timey:
    #   ... through Acton at one.
    #   ... starts opening at eight and ...
    push @r,qr{ $bb_re
                (?<pr>
                  ( $at_words | upon | till | from
                   | ( it | time ) \s+ ( is | was | will \s+ be )
                   | ['‘’] ( twill \s+ be | twas )
                  ) \s+
                  ( only \s+ )?
                )
                (?<t1>
                  ( $rel_words \s+ )?
                  ( near \s+ ( on \s+ )? )?
                  $hour_re ( ( [-:.] | \s+ )? $min0_re )?
                )
                (?! [''‘’]s )
                ( [-\s]* $never_follow_times_re \b (*SKIP)(*FAIL) )?
                (?<po>
                  ( \s+ or \s+ so )?
                  ( [""''‘’“”]
                   | [.…;:?!,] ( [""''‘’“”\s] | \z )
                   | \s+ ( and | till | before | [-—] ) \s+
                  )
                )
                (?{ $branch = "9c:TIMEY"})
              }xin;

    push @r,qr{ \b
                (?<pr> \b $hour24_re )
                (?<t1> \s+ strokes )
                $ba_re
                (?{ $branch = "15:TIMEY"})
              }xin;

    # The only time, but as a single hour (these are less reliable)
    push @r,qr{ (?<pr>
                  ( \A | ['"‘’“”] | [.…;:?!] \s+ | \s+ [-—]+ \s+ )
                  ( ( only | just | it['‘’]?s | it \s+ is | the ) \s+ )?
                )
                (?<t1>
                  ( $rel_words \s+ )?
                  $hour24_word_re ( ( \s+ | [-] ) $min_word_re ( ,? \s* $ampm_re )? )?
                )
                (?<po>
                  ( [-] $minsec_dig_re )?
                  ( \s+ ( now | precisely | exactly ) )?
                  ( \z | [.…;:?!,]? ['"‘’“”] | [.…;:?!,] ( \s+ | \z ) | \s+ [-—]+ \s+) )
                (?{ $branch = "9k:TIMEY"; $branch = "9k:1" if $+{po} =~ /now/; })
              }xin;

    # Untrustworthy times... need an indication that it is a time, not just some number
    # Hours 1-12 only
    #  at 1237, is 1237, was 1237, by 1237
    push @r,qr{ (?<li> $not_in_match )
                (?<pr>
                  ( at ( \s+ last )?
                  | it \s+ ( is | was ) | twas | it['‘’]?s | by
                  ) \s+
                )
                (?<t1>
                  ( $rel_words \s+ )?
                  ( $hour12_dig_re [.]? | $hour24_dig_re [.] )
                    $minsec0_dig_re
                )
                (?! \s+ $never_follow_times_re \b )
                $ba_re
                (?{ $branch = "3:TIMEY"})
              }xin;

    # Untrustworthy times... need an indication that it is a time, not just some number
    # All 24 hours
    #  by 2037 on ...
    push @r,qr{ (?<li> $not_in_match )
                (?<pr>
                  ( at ( \s+ last )?
                  | it \s+ ( is | was ) | twas | it['‘’]?s | by
                  ) \s+
                )
                (?<t1>
                  ( $rel_words \s+ )?
                  $hour_dig_re
                  $minsec0_dig_re
                )
                (?<po> \s+ on \s+ )
                (?{ $branch = "3a:TIMEY"})
              }xin;

    # eleven fifty-six
    push @r,qr{ (?<li> $not_in_match )
                (?<t1>
                  ( $rel_words \s+ )?
                  ( $hour24_word_re ( \s+ | \s* ( \Q...\E | … ) \s* ) $min_word_re
                  | $hour_word_re ( [-\s]+ | \s* ( \Q...\E | … ) \s* ) $min_word_re
                  | $hour_dig_re [-.] $minsec0_dig_re
                  )
                  ( ,? \s* $ampm_re )? )
                (?! \s+ $never_follow_times_re \b
                |  [-—]
                )
                $ba_re
                (?{ $branch = "5a:TIMEY"})
              }xin;

    # after eleven in summer evenings ...
    push @r,qr{ (?<li> $not_in_match )
                (?<t1>
                  $rel_words \s+
                  $hour24_word_re
                  ( ,? \s* $ampm_re )? )
                (?<po> \s+ in \s+ \w+ \s+ ( morn | morning | afternoon | evening ) s? )
                $ba_re
                (?{ $branch = "5h:TIMEY"})
              }xin;

    # Hours by, at start of phrase
    # ; eleven by big ben ...
    push @r,qr{ (?<pr> ( \A | ['"‘’“”] | [.…;:?!,] \s+ ) )
                (?<t1> $hour24_re ( [.\s]+ $min0_re )? )
                (?<po>
                  \s+ ( by ) \s+
                  (?! one \b )
                )
                $ba_re
                (?{ $branch = "5g:TIMEY"})
              }xin;

    # Other ecclesiastical times that conflict
    push @r,qr{ \b
                ( (?<pr> ( when | during ) \s+ )
                | (?<t1> $rel_words \s+ )
                )
                (?<t2> prime | nones )
                $ba_re
                (?{ $branch = "16"})
              }xin;

    # Nearer to one than half past
    push @r,qr{ \b
                (?<t1> nearer \s+ to \s+
                       $hour_re \s+
                       ( $oclock_re \s+ )? than \s+
                       $fraction_re [-\s]+ past
                )
                $ba_re
                (?{ $branch = "17"})
              }xin;

    # I tried to pull her off about 0230, and there ...
    push @r,qr{ (?<li> $not_in_match )
                (?<t1>
                  ( ( $rel_at_words \s+ )? 0\d           $minsec0_dig_re
                  |   $rel_at_words \s+    $hour0_dig_re $minsec0_dig_re
                  )
                  ( ,? \s* $ampm_re )? )
                (?! \s+ $never_follow_times_re \b
                |  [-—]
                |  \. \d+  # Skip dates 19.10.39, Churchill, Gathering Storm
                )
                $ba_re
                (?{ $branch = "18:TIMEY"})
              }xin;

    # The new day was still a minute away
    push @r,qr{ (?<li> $not_in_match )
                (?<pr> the \s+ )
                (?<t1>
                  ( new | next ) \s+ day \s+
                  was \s+ ( ( still | just | $rel_words ) \s+ )?
                  ( ( a | $min_re ) \s+ )?
                  ( ( minute | hour | second ) s? \s+)? away
                )
                $ba_re
                (?{ $branch = "19"})
              }xin;

    # TODO: Military times?
    #   Thirteen hundred hours; Zero five twenty-three; sixteen thirteen

    return(\@r);
}

sub extract_times {
    my ($string, $permute, $adj) = @_;

    my @times;
  MATCH_LOOP:
    while ($string =~ m{<< ([^|>]+) [|] \d+ \w? (:\d)? >>}gx) {
        my $str = $1;
        my $branch;

        my $lnr = qr{ $low_num_re | zero | oh }xin;
        if ($str =~
            m{\A
              ( # Exact time
                ( (?<rl> $rel_at_words ) \s+
                  ( ( at | to ) \s+ )?
                | in \s+ ( (?<rl> $rel_at_words ) \s+ )?
                  (?<n1> $min_re ) \s+ ( minutes? \s+ )?
                  it \s+ (would | will) \s+ be \s+ (a \s+)?
                | (?<rl> close \s+ upon ) \s+
                )?
                  (?<hr> $hour24_re | $all_ecclesiastical ) [-\s.:…]*
                ( (?<mn> $min_re ( (?<rl> - ) $min_re )? ) \s* )?
                ( \s+ $oclock_re )?
                ( [,]? \s* (?<am> $ampm_re   ) )?
                ( ,? \s+ all \s+ but \s+ (?<n1> $min_re ) (\s+ minutes?)? )?
                (?{ $branch = "1"})

              | # 0000h
                ( (?<rl> $rel_at_words ) \s+ )?
                  (?<hr> $hour_dig_re
                  | $lnr ( \s+ $lnr )?
                  ) [-\s.:]*
                ( (?<mn> $minsec0_dig_re
                  | $lnr \s+ $lnr
                  ) \s*
                )?
                ( (?<sec> [:.] $minsec_dig_re ( [-.] $minsec_dig_re )? ) \s* )?
                (?<am> h | hrs | hours )
                (?{ $branch = "2"})

              | # 11h20m, 11h20, 3 hr 8 m p.m.
                ( (?<rl> $rel_at_words ) \s+ )?
                  (?<hr> $hour_dig_re | $hour24_re ) \s* ( h | hr    | hours? )  \s*
                ( \s+ and \s+ | , \s+ )?
                  (?<mn> $minsec_dig_re | $min_re ) \s* ( m | mins? | minutes?  )?
                ( ,? \s+ (?<am> $ampm_re ) )?
                (?{ $branch = "3"})

              | # twenty minutes past eight
                ( (?<rl> $rel_at_words | a \s+ few | just ) \s+
                | (?<rl> ( $rel_at_words \s+ )? $min_re \s+ or ) \s+
                )?
                ( (?<mn> $min_re | a ) [-\s]+ )?
                ( and ( \s+ | [-] )
                  ( a \s+ half | 1/2 | a \s+ quarter | 1/4 ) \s+
                )?
                  ( minutes? \s+ )?
                ( and ( \s+ | [-] ) (?<sec> $sec_re ) \s+ seconds? \s+ )?
                  (?<dir> $till_re ) [-\s]+
                  ( the \s+ hour [,;]? \s+ which \s+ was \s+ )?
                  (?<hr> $hour24_re )
                ( [-\s]+ (?<m3> $min_re ) )?
                ( \s+ $oclock_re )?
                ( ,? \s* (?<am> $ampm_re ) )?
                (?{ $branch = "4"})

              | # seven-and-twenty minutes past eight
                ( (?<rl> $rel_at_words | between ) \s+ )?
                  (?<mn> $min_re [-\s+] and [-\s+] $min_re ) \s+
                  ( and ( \s+ | [-] )
                    (?<sec> a \s+ half | 1/2 | a \s+ quarter | 1/4 | twenty
                    | (?<sec> $sec_re ) \s+ second s?
                    ) \s+
                  )?
                  ( minutes? \s+ )?
                  (?<dir> $till_re ) \s+
                  (?<hr> $hour_re )
                ( \s+ $oclock_re )?
                ( ,? \s* (?<am> $ampm_re ) )?
                (?{ $branch = "5"})

              | # three quarters past eleven
                ( in \s+ ( (?<rl> $rel_at_words ) \s+ )?
                  (?<n1> $min_re ) \s+ ( minutes? \s+ )?
                  it \s+ (would | will) \s+ be \s+ (a \s+)?
                )?
                ( ( (?<m2> $min_re ) \s+ minutes? \s+ )?
                  (?<rl> $rel_at_words ) \s+ ( a \s+ )?
                  ( the \s+ )?
                )?
                  (?<mn> $fraction_re ) [-\s]+
                  (?<dir> $till_re ) \s+
                  (?<hr> $hour_re )
                ( \s+ $oclock_re )?
                ( ,? \s+ (?<am> $ampm_re ) )?
                (?{ $branch = "6"})

              | # three o'clock
                ( (?<rl> $rel_at_words ) \s+ )?
                  (?<hr> $hour24_re ) \??
                  [-\s]+ $oclock_re
                ( ,? \s+ (?<am> $ampm_re ) )?
                ( \s+ ( and \s+ )?
                  (?<mn> $min_re | $fraction_re ) \s*
                  minutes?
                )?
                (?{ $branch = "7"})

              | # One hour and a quarter
                ( (?<rl> $rel_at_words ) \s+ )?
                  (?<hr> $hour_re ) \s+ hours? \s+ and \s+ a \s+
                  (?<mn> $fraction_re )
                ( ,? \s+ (?<am> $ampm_re ) )?
                (?{ $branch = "8"})

              | # one ... thirty ... four
                ( (?<rl> $rel_at_words ) \s+ )?
                  (?<hr> $hour24_word_re ) ( [\s\.]+ | [-] )
                  (?<mn> $min_word_re )
                ( \s* ... \s* (?<m3> $low_num_re ) )?
                ( \s+ $oclock_re )?
                ( ,? \s+ (?<am> $ampm_re ) )?
                (?{ $branch = "9"})

              | # Two minutes before the clock struck noon
                  (?<mn> $min_word_re ) \s+ minutes? \s+
                  (?<dir> $till_re ) \s+
                ( the \s+ clock \s+ struck \s+ )?
                  (?<hr> $hour24_re )
                ( \s+ $oclock_re )?
                ( ,? \s+ (?<am> $ampm_re ) )?
                (?{ $branch = "10"})

              | # 4.15 o'clock
                ( (?<rl> $rel_at_words ) \s+ )?
                  (?<hr> $hour24_re ) [.:\s]+
                  (?<mn> $min_re )
                  (?<dir> $till_re ) \s+
                ( the \s+ clock \s+ struck \s+ )?
                ( \s+ $oclock_re )?
                ( ,? \s+ (?<am> $ampm_re ) )?
                (?{ $branch = "11"})

              | # nearer to one than half past
                  (?<rl> nearer \s+ to ) \s+
                  (?<hr> $hour24_re ) \s+
                  ( $oclock_re \s+ )? than \s+
                  (?<mn> $fraction_re ) [-\s]+ past
                ( ,? \s+ (?<am> $ampm_re ) )?
                (?{ $branch = "12"})

              | # nearer to one than half past
                  ( new | next ) \s+ (?<hr> day) \s+
                  was \s+ ( ( still | just | $rel_words ) \s+ )?
                  ( (?<n1> a | $min_re ) \s+ )?
                  ( (?<un> minute | hour | second ) s? \s+)? away
                (?{ $branch = "13"})

              )
              \z}xin)
        {
            # Save the captured values
            my @k = qw{ rl mn m2 m3 n1 dir hr am sec branch };
            my %c; @c{@k} = @+{@k};
            $c{branch} = $branch;

            my $min  = $c{mn}  // 0;             # The base minutes
            my $m2   = $c{m2}  // 0;             # Additional minutes elsewhere in the string
            my $m3   = $c{m3}  // 0;             # Further minutes elsewhere in the string
            my $n3   = $c{n1}  // 0;             # Negative value in the string
            my $un   = $c{un}  // 'minutes';     # The units of the negative value
            my $sec  = defined $c{sec} ? 1 : 0;  # Seconds present?
            my $hour = $c{hr}  // 0;             # The base hour
            my $rel  = $c{rl}  // '';            # The relative phrase
            my $ampm = $c{am};                   # AM or PM?
            my $dir  = $c{dir} // '';            # Whether the time is before or after the base hour

            my $abs_hour = 0;

            # Turn the hours into numbers
            if ($hour !~ /^\d+$/) {
                if ($hour =~ $all_ecclesiastical) {
                    # Handle special named times

                    # Ecclesiastical times
                    #  Per Eco in "The Name of the Rose"
                    #  See also: https://en.wikipedia.org/wiki/Liturgy_of_the_Hours
                    my %time_strs =
                        ('matins'       => ["02:30 AM",       "03:00 AM", 30], # Between 2:30 & 3:00 AM
                         'vigils'       => ["02:30 AM",       "03:00 AM", 30], # Between 2:30 & 3:00 AM
                         'nocturns'     => ["02:30 AM",       "03:00 AM", 30], # Between 2:30 & 3:00 AM
                         'night office' => ["02:30 AM",       "03:00 AM", 30], # Between 2:30 & 3:00 AM
                         'lauds'        => ["05:00 AM",       "06:00 AM", 00], # Between 5:00 & 6:00 AM
                         'prime'        => ["around 7:30 AM", undef,      00],
                         'terce'        => ["around 9:00 AM", undef,      00],
                         'sext'         => ["noon",           undef,      00],
                         'nones'        => ["02:00 PM",       "03:00 PM", 60], # Between 2:00 & 3:00 PM
                         'vespers'      => ["around 4:30 PM", undef,      00],
                         'compline'     => ["around 6:00 PM", undef,      00],
                        );
                    my $tr = $time_strs{lc($hour)}
                      or die "Unable to work out a time for '$hour'";

                    # Handle times relative to this. i.e. just before matins
                    my ($start_str, $end_str, $adj) = @$tr;
                    $end_str //= $start_str;
                    my ($rs, $ts, $as) = ('', $start_str, $adj);

                    if ($rel ne '') {
                        if ($rel =~ m{\A ( $far_before_re
                                         | $short_before_re
                                         | close ( \s+ upon )?
                                         ) \z}xin
                            )
                        {
                            ($rs, $ts, $as) = ($rel, $start_str, 0);
                        }
                        elsif ($rel =~ m{\A $around_re \z}xin) {
                            if (not $as) {
                                ($rs, $ts, $as) = ($rel, $start_str, 0);
                            }
                        }
                        elsif ($rel =~ m{\A ( $short_after_re | $far_after_re ) \z}xin) {
                            ($rs, $ts, $as) = ($rel, $end_str, 0);
                        }
                        else {
                            confess "Can't parse '$rel'";
                        }

                        $rs .= " ";
                        $ts =~ s{\A around \s }{}xin;
                    }

                    push @times, extract_times("<<$rs$ts|88>>", $permute, $as);
                    next MATCH_LOOP;
                }

                # Handle normal times
                if ($hour =~ $noon_re) {
                    $hour = 12;
                    $abs_hour = 1;
                }
                elsif ($hour =~ $midnight_re or $hour =~ /day/i) {
                    $hour = 00;
                    $abs_hour = 1;
                }
                else {
                    $hour = min2num($hour);
                }
            }

            # Turn the minutes into numbers
            if ($min !~ /^\d+$/) {
                if ($rel eq 'between') {
                    $min =~ s{ \A (.*?) \s+ and \s+ .* \z }{$1}xi;
                }
                elsif ($rel eq '-') {
                    $min =~ s{ \A (.*) - .* \z }{$1}xi;
                    $dir = 'after';
                }
                $min = min2num($min);

                $min -= 30 if $rel =~ m{\A nearer \s+ to \z}xin and $min == 30;
            }
            $min += min2num($m2);

            # If we got am or pm we can set the hour absolutely
            if (defined $ampm) {
                $abs_hour = 1;
                my $pm = undef;

                if ($ampm =~ m{\A $in_the_re \z}xin) {
                    # Work out the time
                    if ($ampm =~ m{ morning | mornin['‘’]? | morn | dawn | sunrise }xi) {
                        $pm = 0;
                    } elsif ($ampm =~ m{ afternoon | evening | eve | dusk | sunset }xi) {
                        $pm = 1;
                    }
                    elsif ($ampm =~ m{ day }xi) {
                        # Day means 6AM to 6PM
                        $hour += 12 if $hour <= 5;
                    }
                    elsif ($ampm =~ m{ night }xi) {
                        # Night means 0-6AM and 6-12PM
                        $hour += 12 if $hour >= 5 and $hour <= 12;
                    }
                    else {
                        confess "Can't parse ampm '$ampm'";
                    }
                }
                elsif ($ampm =~ m{\A $ampm_only_re \z}xin) {
                    $pm = $ampm =~ /^p/i ? 1 : 0;
                }
                elsif ($ampm =~ m{\A (h | hrs | hours) \z}xin) {
                    # Military times
                }
                else {
                    confess "Can't parse ampm '$ampm'";
                }

                if (defined $pm) {
                    if ($hour == 12 and $min == 00) {
                        # 12:00 am/pm is ambiguous let it be both
                        $hour = 0;
                        $abs_hour = 0;
                    }
                    elsif ($pm) {
                        # PM
                        $hour += 12
                            if $hour != 12;
                    } else {
                        # AM
                        if ($hour == 12) {
                            $hour = 0;
                        }
                    }
                }
            }
            elsif (not $abs_hour) {
                if ($hour > 12 or $hour == 0) {
                    # Otherwise, depending on the hour, there can only be one choice
                    $abs_hour = 1;
                }
                elsif ($hour == 12) {
                    # 12:20 could be either am or pm, so set it low so we get both
                    $hour = 0;
                }
            }

            # Look at the direction and see if we need to subtract the minutes rather than add
            if ($dir =~ $before_re) {
                $min = - $min;
                $min -= 1 if $sec;
            }

            # Always add in the m3, it's never negative
            $min += min2num($m3);

            # Always subtract the n1, it's always negative
            if ($un =~ /hour/i) {
                $hour -= min2num($n3);
            }
            elsif ($un =~ /second/i) {
                $min -= 1;
            }
            else {
                $min -= min2num($n3);
            }

            # If we are in the afternoon then we are absolute
            $abs_hour = 1 if $hour > 12;

            # If the hour rolled, then we need to set it back
            $hour %= 24;

            my @hours = $hour;
            my @mins  = $min;
            my ($low, $high, $exp) = get_spread($rel, $dir, $c{mn});

            $high += ( $adj || 0 );
            if ($permute) {
                # If we are permuting, we don't need the relative expression
                $exp = '';

                # Handle the 12 hour clock ambiguity
                push @hours, $hour+12
                    unless $abs_hour;

                # Handle relative times by spreading the range
                @mins = ();
                for my $d ($low .. $high) {
                    push @mins, $min + $d;
                }
            }
            else {
                if (not $abs_hour) {
                    $exp = $exp eq '' ? 'ap' : "ap $exp";
                }
            }

            foreach my $h (@hours) {
                foreach my $m (@mins) {
                    my ($hour, $min) = fix_time($h, $m);
                    my $t = sprintf("%02d:%02d", $hour, $min);

                    $exp = $exp . ' '
                        if $exp ne '';

                    my $time = "$exp$t: " . join(" ",  map { defined $c{$_} ? "$_<$c{$_}>" : () } @k );

                    push @times, $time;
                }
            }
        }
    }

    return @times;
}

sub fix_time {
    my ($h, $m) = @_;

    if ($m < 0) {
        $h -= 1;
        $m += 60;
    }
    elsif ($m > 59) {
        $h += 1;
        $m -= 60;
    }

    $h %= 24;

    return ($h, $m);
}

sub min2num {
    my ($min) = @_;
    confess "Missing arg min"
        unless defined $min;

    # Digits
    return $min if $min =~ m{\A \d+ \z}xin;

    # Fixed numbers
    return 0  if $min =~ m{\A ( oh \s* )+ \z}xin;
    return 1  if $min =~ m{\A ( a ) \z}xin;

    # Fractions
    return 15 if $min =~ m{\A ( quarter | 1/4 ) \z}xin;
    return 20 if $min =~ m{\A ( third   | 1/3 ) \z}xin;
    return 30 if $min =~ m{\A ( half    | 1/2 ) \z}xin;
    return 45 if $min =~ m{\A ( three [-\s]+ quarters
                              | third \s+ quarter
                              | 3/4
                              ) \z}xin;

    # Lose the leading oh-
    $min =~ s{\A ( oh [-\s]+ ) }{}xin;

    $min = words2nums($min)
        // confess "Can't parse minute '$min'";

    return $min;
}

sub get_spread {
    my ($rel, $dir, $min) = @_;

    if ($rel eq '' and defined $dir and $dir ne '' and not defined $min) {
        return (-9, -1, '<')  if $dir =~ $before_re;
        return ( 1,  9, '>')  if $dir =~ $after_re;
    }

    return (  0,  0, ''  )  if $rel eq '';
    return (-15, -5, '<<')  if $rel =~ m{\A $far_before_re   \z}xin;
    return ( -9, -1, '<' )  if $rel =~ m{\A ( $short_before_re
                                      | close ( \s+ upon )?
                                      ) \z}xin;
    return ( -6,  6, '~' )  if $rel =~ m{\A $around_re       \z}xin;
    return (  0,  6, '~' )  if $rel =~ m{\A $on_or_after_re  \z}xin;
    return (  1,  9, '>' )  if $rel =~ m{\A $short_after_re  \z}xin;
    return (  5, 15, '>>')  if $rel =~ m{\A $far_after_re    \z}xin;

    if (defined $dir and $dir ne '') {
        if ($rel =~ m{\A ( (?<m> $min_re ) \s+ or
                     | (?<r> a \s+ few | just )
                     )
                     \z}xin)
        {
            my $rmin = defined $+{m} ? min2num($+{m}) : 5;
            if (defined $min and $min ne '') {
                # We already used the min to set the time, so take that away from the spread
                $rmin -= min2num($min);
            }

            if ($dir =~ $before_re) {
                return (-$rmin, 0, '<');
            }
            return (0, $rmin, '>');
        }
        elsif ($rel =~ m{\A ( between | - ) \z}xin and
               $min =~ m{\A (?<a> $min_re)
                            ( \s+ ( and | or ) \s+
                            | -
                            )
                            (?<b> $min_re) \z
                        }xin)
        {
            my $a = min2num($+{a});
            my $b = min2num($+{b});

            # Since we've already consumed the first number as minutes, we need to adjust by that
            $b -= $a;
            $a  = 0;

            if ($dir =~ $before_re) {
                return (-$b, 0, '-');
            }
            return (0, $b, '-');
        }
    }
    else {
        return ( 0,  0, '' )  if $rel =~ m{\A ( until | at ) \z}xin;
        return (-5, -1, '<')  if $rel =~ m{\A ( before ) \z}xin;

        return ( 1, 15, '+') if "$rel $min" =~ m{\A nearer \s+ to \s+ half \z}xin;
    }

    confess "Can't parse rel '$rel'";
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
