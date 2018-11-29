use Modern::Perl '2017';

use utf8;
use open ':std', ':encoding(UTF-8)';
use Test::Modern;

use lib '.';
use lib 't';

use TimeMatchTest;

# prove t/01-test.pl |& egrep -E '^|<<[^>]+(>>|$)|^[^<>]+>>'

check_substring(get_csv_tests());

done_testing;

exit;