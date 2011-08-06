# XXX Very simplistic for now - really we'll need to steal much of the stuff
# in the existing Perl6::Module::Loader and Perl6::Module::Locator, though enough
# of it is wrong (e.g. importing) that this will look quite different anyway.
class Perl6::ModuleLoader {
    my %modules_loaded;
    my %settings_loaded;
    
    method ctxsave() {
        $*MAIN_CTX := Q:PIR {
            getinterp $P0
            %r = $P0['context';1]
        };
        $*CTXSAVE := 0;
    }
    
    method search_path() {
        # See if we have an @*INC set up, and if so just use that.
        my $hll_ns := pir::get_root_global__PS('perl6');
        if pir::exists($hll_ns, 'PROCESS') && pir::exists($hll_ns<PROCESS>.WHO, '@INC') {
            my $INC := ($hll_ns<PROCESS>.WHO)<@INC>;
            if pir::defined($INC) {
                my @INC := $INC.ARGLIST_FLATTENABLE();
                if +@INC {
                    return @INC;
                }
            }
        }
        
        # Too early to have @*INC; probably no setting yet loaded to provide
        # the PROCESS initialization.
        my @search_paths;
        @search_paths.push('.');
        @search_paths.push('blib');
        my %conf := pir::getinterp__P()[pir::const::IGLOBALS_CONFIG_HASH];
        @search_paths.push(%conf<libdir> ~ %conf<versiondir> ~
            '/languages/perl6/lib');
        # XXX CHEAT: Goes away when we implement :from<nqp>.
        @search_paths.push(%conf<libdir> ~ %conf<versiondir> ~
            '/languages/nqp/lib');
        @search_paths
    }
    
    method load_module($module_name, $cur_GLOBALish) {
        # If we didn't already do so, load the module and capture
        # its mainline. Otherwise, we already loaded it so go on
        # with what we already have.
        my $module_ctx;
        my $path := pir::join('/', pir::split('::', $module_name)) ~ '.pbc';
        my @prefixes := self.search_path();
        for @prefixes -> $prefix {
            if pir::stat__isi("$prefix/$path", 0) {
                $path := "$prefix/$path";
                last;
            }
        }
        if pir::defined(%modules_loaded{$path}) {
            $module_ctx := %modules_loaded{$path};
        }
        else {
            my %*COMPILING := {};
            my $*CTXSAVE := self;
            my $*MAIN_CTX;
            my $preserve_global := pir::get_hll_global__Ps('GLOBAL');
            pir::load_bytecode($path);
            pir::set_hll_global__vsP('GLOBAL', $preserve_global);
            %modules_loaded{$path} := $module_ctx := $*MAIN_CTX;
        }

        # Provided we have a mainline...
        if pir::defined($module_ctx) {
            # Merge any globals.
            my $UNIT := pir::getattribute__PPs($module_ctx, 'lex_pad');
            unless pir::isnull($UNIT<GLOBALish>) {
                merge_globals($cur_GLOBALish, $UNIT<GLOBALish>);
            }
        }

        return $module_ctx;
    }
    
    # XXX This is a really dumb and minimalistic GLOBAL merger.
    # For a much more complete one, see sorear++'s work in
    # Niecza. This one will likely evolve towards that.
    my $stub_how := 'PackageHOW';
    sub merge_globals($target, $source) {
        # Start off merging top-level symbols. Easy when there's no
        # overlap. Otherwise, we need to recurse.
        my %known_symbols;
        for $target.WHO {
            %known_symbols{$_.key} := 1;
        }
        for $source.WHO {
            my $sym := $_.key;
            if !%known_symbols{$sym} {
                ($target.WHO){$sym} := $_.value;
            }
            elsif ($target.WHO){$sym} =:= $_.value {
                # No problemo; a symbol can't conflict with itself.
            }
            else {
                my $source_mo := $_.value.HOW;
                my $source_is_stub := $source_mo.WHAT.HOW.name($source_mo) eq $stub_how;
                my $target_mo := ($target.WHO){$sym}.HOW;
                my $target_is_stub := $target_mo.WHAT.HOW.name($target_mo) eq $stub_how;
                if $source_is_stub && $target_is_stub {
                    # Leave target as is, and merge the nested symbols.
                    merge_globals(($target.WHO){$sym}, $_.value);
                }
                # XXX Two other recursive cases go here.
                else {
                    pir::die("Merging GLOBAL symbols failed: duplicate definition of symbol $sym");
                }
            }
        }
    }
    
    method load_setting($setting_name) {
        my $setting;
        
        if $setting_name ne 'NULL' {
            # Add path prefix and .setting suffix.
            my $path := "$setting_name.setting.pbc";
            my @prefixes := self.search_path();
            for @prefixes -> $prefix {
                if pir::stat__isi("$prefix/$path", 0) {
                    $path := "$prefix/$path";
                    last;
                }
            }
        
            # Unless we already did so, load the setting.
            unless pir::defined(%settings_loaded{$path}) {
                my $*CTXSAVE := self;
                my $*MAIN_CTX;
                my $preserve_global := pir::get_hll_global__Ps('GLOBAL');
                pir::load_bytecode($path);
                pir::set_hll_global__vsP('GLOBAL', $preserve_global);
                unless pir::defined($*MAIN_CTX) {
                    pir::die("Unable to load setting $setting_name; maybe it is missing a YOU_ARE_HERE?");
                }
                %settings_loaded{$path} := $*MAIN_CTX;
            }
            
            $setting := %settings_loaded{$path};
        }
        
        return $setting;
    }
}

# We stash this in the perl6 HLL namespace, just so it's easy to
# locate. Note this makes it invisible inside Perl 6 itself.
pir::set_root_global__vPsP(['perl6'], 'ModuleLoader', Perl6::ModuleLoader);
