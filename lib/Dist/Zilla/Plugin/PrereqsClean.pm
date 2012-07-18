package Dist::Zilla::Plugin::PrereqsClean;

our $VERSION = '0.9'; # VERSION
# ABSTRACT: Automatically cleans up the mess from other Prereq modules

use sanity;

use Moose;
use MetaCPAN::API;
use Module::CoreList;
use List::Util qw(min max);
use version 0.77;

with 'Dist::Zilla::Role::PrereqSource';

has minimum_perl => (
   is      => 'ro',
   isa     => 'Str',
   lazy    => 1,
   default => sub {
      $_[0]->zilla->prereqs->requirements_for('runtime', 'requires')->requirements_for_module('perl') ||
      'v5.8.8'  # released in 2006... C'mon, people!  Don't make me lower this!
   }
);

use constant {
   RL_NONE          => 0,
   RL_CORE_ONLY     => 1,
   RL_DIST_NO_SPLIT => 2,
   RL_DIST_ALL      => 3,
};

has removal_level => (
   is  => 'ro',
   isa => 'Bool',
   default => RL_DIST_NO_SPLIT,
);

sub register_prereqs {
   my ($self) = @_;
   my $zilla   = $self->zilla;
   my $prereqs = $zilla->prereqs->cpan_meta_prereqs;
   
   my $default_perlver = version->parse( $self->minimum_perl );
   foreach my $phase (qw(runtime configure build)) {
      my $req = $prereqs->requirements_for($phase, 'requires');
      my $phase_perlver = version->parse( $req->requirements_for_module('perl') );
      $default_perlver = max($phase_perlver, $default_perlver) if ($phase_perlver);
   }

   my $latest_perlver = version->parse( (reverse sort keys %Module::CoreList::released)[0] );
   $self->log_debug([ 'Default Perl %s, Latest Perl %s', $default_perlver->normal, $latest_perlver->normal ]);

   # Look for specific things that would change the Perl version
   $self->logger->set_prefix("{Pass 1: Core} ");
   foreach my $phase (qw(runtime configure build test)) {
      $self->log_debug("Phase '$phase'");
      my $req = $prereqs->requirements_for($phase, 'requires');
      my $perlver = version->parse( $req->requirements_for_module('perl') ) || $default_perlver;
      $perlver = $default_perlver if ($default_perlver > $perlver);

      foreach my $module (sort ($req->required_modules) ) {
         # (speeding through this stuff for this run...)
         next if $module eq 'perl';  # obvious
         #$self->log_debug([ 'Module %s, PerlVer %s',  $module, $perlver->normal ]);
         next if Module::CoreList->is_deprecated($module, $latest_perlver);
         next if Module::CoreList->removed_from($module);
         my $modver = $req->requirements_for_module($module);
         next if ( $modver =~ /\s/ );
         $modver = version->parse($modver);
         my $modver_log = $module.($modver ? ' '.$modver->normal : '');
         
         # Core module (might as well deal with this whole block while we're here...)
         if ( my $release = version->parse( Module::CoreList->first_release($module, $modver) ) ) {
            
            if ($release > $perlver) {
               my $distro = $self->_mcpan_module2distro($module);
               next unless ($distro);

               if ($distro eq 'perl') {
                  $self->log([ 'Module %s is only found in core Perl; adding Perl %s requirement', $modver_log, $release->normal ]);
                  $req->clear_requirement($module);
                  $req->add_minimum( perl => $release );
                  
                  $perlver = $release;
                  $default_perlver = $release if ($phase =~ /configure|runtime|build/);
               }
               next;
            }
            next unless ($self->removal_level);
            $self->log_debug([ 'Removing core module %s (been available since Perl %s)', $modver_log, $release->normal ]);
            $req->clear_requirement($module);
         }
      }
   }

   $prereqs->requirements_for('runtime', 'requires')->add_minimum( perl => $default_perlver );
   
   # Okay, clean up the remaining Perl core modules (if any), and any non-cores
   my $distro_mods = {};
   foreach my $phase (qw(runtime configure build test)) {
      $self->logger->set_prefix("{Pass 2.1: Modules} ");
      $self->log_debug("Phase '$phase'");
      my $req = $prereqs->requirements_for($phase, 'requires');
      $distro_mods = {} if ($phase eq 'test');
      my %distro_list;  # only saved this phase vs. $distro_mods

      my $perlver = version->parse( $req->requirements_for_module('perl') );
      # Do some general cleanup of the 'perl' version specifically
      if ($default_perlver >= $perlver) {
         $perlver = $default_perlver;
         $req->clear_requirement('perl') if ($phase =~ /configure|build/);
      }
      
      foreach my $module (sort ($req->required_modules) ) {
         next if $module eq 'perl';  # obvious
         
         # Skips
         if ( Module::CoreList->is_deprecated($module, $latest_perlver) ) {
            $self->log([ 'Module %s is deprecated in the latest core Perl (%s); you should consider alternatives...', $module, $latest_perlver->normal ]);
            next;
         }
         if ( my $remver = version->parse( Module::CoreList->removed_from($module) ) ) {
            $self->log([ 'Module %s has been removed from core since Perl %s; you should consider alternatives...', $module, $remver->normal ]);
            next;
         }
         next unless ($self->removal_level);
         
         my $modver = $req->requirements_for_module($module);
         if ( $modver && $modver =~ /\s/ ) {
            # what I really want is $req->is_simple($module)...
            # also, using "complete hack" from is_simple: https://metacpan.org/source/CPAN::Meta::Requirements#L159
            $self->log_debug("Skipping module $module with complex requirements");
            next;
         }
         $modver = version->parse($modver);
         my $modver_log = $module.($modver ? ' '.$modver->normal : '');
         
         # Core module
         if ( my $release = version->parse( Module::CoreList->first_release($module, $modver) ) ) {
            if ($release > $perlver) {
               $self->log_debug([ 'Skipping core module %s (Perl %s > %s)', $modver_log, $release->normal, $perlver->normal ]);
               next;
            }
            $self->log_debug([ 'Removing core module %s (been available since Perl %s)', $modver_log, $release->normal ]);
            $req->clear_requirement($module);
            next;
         }

         # potentials for culling
         next unless ($self->removal_level >= RL_DIST_NO_SPLIT);
         my $distro = $self->_mcpan_module2distro($module) || next;
         
         $distro_mods->{$distro} //= {};
         $distro_mods->{$distro}{$module} = 1;
         $distro_list{$distro} = 1;
      }
      next unless ($self->removal_level >= RL_DIST_NO_SPLIT);
      
      # Look through the collected distro lists and figure out which should be removed
      $self->logger->set_prefix("{Pass 2.2: Distros} ");
      foreach my $distro (sort keys %distro_list) {
         my @modules = sort { length($a) <=> length($b) } keys %{$distro_mods->{$distro}};
         if (@modules <= 1) {
            $self->log_debug("Skipping distro $distro; only has one module requirement");
            next;
         }
         
         # hopefully, we can find a common name to use
         (my $dmodule = $distro) =~ s/-/::/g;
         my $details = $self->_mcpan_module2distro($dmodule);
         my $main_module = $dmodule if ($details);
         $main_module ||= $modules[0];
         
         # remove any obvious split potentials
         if ($self->removal_level <= RL_DIST_NO_SPLIT) {
            (my $parent_module = $main_module) =~ s/::\w+$//;
            @modules = grep { /^\Q$dmodule\E|^\Q$parent_module\E/ } @modules;
            if (@modules <= 1) {
               $self->log_debug("Skipping distro $distro; only has ".scalar @modules." module left since split comparison");
               next;
            }
         }
         
         my $maxver = max map { version->parse( $req->requirements_for_module($_) ) } @modules;
         $maxver ||= 0;

         $self->log_debug("Replacing modules from common distro $distro:");
         $self->log_debug('   Using main/replacement module of '.$main_module.($maxver ? ' '.$maxver->normal : ''));
         $self->log_debug("   $_") for @modules;
         $req->clear_requirement($_) for @modules;
         $req->add_minimum( $main_module => $maxver );
      }
   }
}

my $mcpan = MetaCPAN::API->new();
sub _mcpan_module2distro {
   my ($self, $module) = @_;
   
   # faster and less bulky than a straight module/$module pull
   ### XXX: This should be replaced with a ->file() method when those
   ### two pull requests of mine are put into CPAN...
   $self->log_debug("Checking module $module via MetaCPAN");
   my $details = $mcpan->fetch("file/_search", 
      q      => 'module.name:"'.$module.'" AND status:latest AND module.authorized:true',
      fields => 'distribution',
      size   => 1,
   );
   unless ($details && $details->{hits}{total}) {
      $self->log("??? MetaCPAN can't even find module $module!");
      return undef;
   }
   return $details->{hits}{hits}[0]{fields}{distribution};
}

__PACKAGE__->meta->make_immutable;
42;



=pod

=encoding utf-8

=head1 NAME

Dist::Zilla::Plugin::PrereqsClean - Automatically cleans up the mess from other Prereq modules

=head1 SYNOPSIS

    ; ...other Prereq plugins...
    ; (NOTE: Order is important, so PrereqsClean should go last.)
    [PrereqsClean]
    ; defaults
    minimum_perl = {{Runtime Requires for Perl}} || v5.8.8
    removal_level = 2

=head1 DESCRIPTION

Ever notice that it's really easy to figure out if a module's author used Dist::Zilla by
the amount of dependencies?  strict?  warnings?  base?  Every module for Foo::Bar::*,
individually listed?

Well, now you can clean up that junk.  PrereqsClean will find and clean up:

=over

=item *

Core modules that are already in Perl, verifying minimum version requirements

=item *

Core modules that B<only> exist in Perl, which will elevate the minimum Perl version if
necessary

=item *

Multiple modules that already exist in a single distribution

=back

=head2 Why bother?

Why even worry about the dependency list?  

=over

=item 1.

Your list of dependencies should give users a general idea of how many B<distributions>
they need to download from CPAN.  Bulking up the dependencies with every single little
module scares away certain users into thinking your module is just too complex to worry
about.

=item 2.

The core module search alone will aid you in setting the most accurate minimum Perl
version.

=item 3.

It's just silly to add in stuff like C<<< strict >>> and C<<< warnings >>> as dependencies, when they
have literally been a part of the Perl language since Day 1.

=back

For the flip side, see L</CAVEATS>.

=head1 OPTIONS

=head2 minimum_perl

This is the bare minimum version of Perl you want to start off with.  Some people already
have a minimum in their code, which it will use by default.  Otherwise, you can override
here, instead of inside the modules.

The "last resort" default is v5.8.8, which is the minimum version of Perl that included
L<ExtUtils::MakeMaker|EUMM>.

=head2 removal_level

This dictates just how zealous this module should remove dependencies from the list.  The
default (level 2) should work fine for most people.

=over

=item *

B<Level 0> = This is the completely safe and boring option.  It won't actually remove
anything unless the module exists B<only> in Perl, which dependencies wouldn't have fixed
anyway.  It will also elevate your minimum Perl version from that discovery, and warn you
of deprecatedE<sol>removed modules from core Perl.

=item *

B<Level 1> = This is the "core only" removal level, which adds support to remove
"dual-life" (CPAN+Perl) core modules, if the minimum version is covered in the existing
version of Perl.

=item *

B<Level 2> = This is the default removal level, which will condense multiple modules into
a single distribution requirement.

=item *

B<Level 3> = This level will remove the "split protection" safeguards that allow it to only
remove multiple modules if they fall into the same parent namespace.  (For example, split
protection would remove all of the C<<< Foo::Bar::\* >>> modules as one C<<< Foo::Bar >>> requirement, and
the C<<< Blah::\* >>> modules as a C<<< Blah >>> requirement, even if all of those modules are in the same
distribution.)

=back

=head1 CAVEATS

=head2 Core module deprecation

B<Situation:> Once in a blue moon, the Perl folks will decide that a module is either too old, too
broken, or too obscure to keep into core.  Once that happens, there is a deprecation process.
First, the module is marked as deprecated for an entire major release cycle (C<<< 5.##.\* >>>).  If it 
was in the middle of a cycle, it will likely last another full cycle.

Finally, the module is removed from core.  In many cases, the module isn't even available on
CPAN, since the whole thing has been retired.

B<Problem:> If PrereqsClean removed the module and if you haven't had a release in a large span
of time (missing the entire deprecation cycle), then users might experience missing dependencies
for newer versions of Perl.

B<Risk:> As of the time of this writing, out of the 773 modules that have ever been in Perl core,
32 modules or module sets (93 indiv modules) have been removed from core, 10 of which were removed
during a massive cleanup during the 5.8E<sol>9 cycle.

Given that you're using something as modern as L<Dist::Zilla>, you're probably not depending on 
modules that are 10 years old.  And you're probably releasing often enough that you'll run into
the built-in deprecation warning before it gets removed.

B<Solution:> If the module is still in CPAN, re-release your distro.  Problem solved.

If not, you're pretty much SOL, anyway.  Switch to a different module.

=head2 Distribution split

B<Situation:> An author of a large distribution has decided that some of the modules are better off
split up into another (or more) distro.

B<Problem:> If PrereqsClean removed the module from the split, then users might experience missing
dependencies.  However, the chances are high that the distro author is now including the split
modules in their dependency list, so CPAN will install it correctly, anyway.

B<Risk:> This is a very rare event, but it does happen to major modules.  For example, GAAS had
split off all of the non-LWP modules from L<libwww-perl> for his 6.0 release.  However, again, 
he also included dependency links back to those modules, so CPAN would have installed it
correctly.  Plus, it was a logical namespace split, so PrereqsClean's "split protection" would 
have already safeguarded against any problems.

So, the odds of this causing any problems are very, very low.

B<Solution:> Again, C<<< dzil release >>>.  Problem solved.

=head2 TL;DR

If any of this is too scary for you, just set the removal_level to 0.

=head1 SEE ALSO

Other Dist::Zilla Prereq plugins: L<Dist::Zilla::Plugin::Prereqs|Prereqs>, L<Dist::Zilla::Plugin::AutoPrereqs|AutoPrereqs>,
L<Dist::Zilla::Plugin::LatestPrereqs|LatestPrereqs>, L<Dist::Zilla::Plugin::DarkPAN|DarkPAN>

=head1 AVAILABILITY

The project homepage is L<https://github.com/SineSwiper/Dist-Zilla-Plugin-PrereqsClean/wiki>.

The latest version of this module is available from the Comprehensive Perl
Archive Network (CPAN). Visit L<http://www.perl.com/CPAN/> to find a CPAN
site near you, or see L<https://metacpan.org/module/Dist::Zilla::Plugin::PrereqsClean/>.

=for :stopwords cpan testmatrix url annocpan anno bugtracker rt cpants kwalitee diff irc mailto metadata placeholders metacpan

=head1 SUPPORT

=head2 Internet Relay Chat

You can get live help by using IRC ( Internet Relay Chat ). If you don't know what IRC is,
please read this excellent guide: L<http://en.wikipedia.org/wiki/Internet_Relay_Chat>. Please
be courteous and patient when talking to us, as we might be busy or sleeping! You can join
those networks/channels and get help:

=over 4

=item *

irc.perl.org

You can connect to the server at 'irc.perl.org' and join this channel: #distzilla then talk to this person for help: SineSwiper.

=back

=head2 Bugs / Feature Requests

Please report any bugs or feature requests via L<L<https://github.com/SineSwiper/Dist-Zilla-Plugin-PrereqsClean/issues>|GitHub>.

=head1 AUTHOR

Brendan Byrd <BBYRD@CPAN.org>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2012 by Brendan Byrd.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=cut


__END__

