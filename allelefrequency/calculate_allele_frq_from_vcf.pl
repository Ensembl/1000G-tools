#!/usr/bin/perl -w

use strict;
use Getopt::Long;
use IPC::System::Simple qw(system);

my ($vcf,
	$sample_panel,
	$user_input_pop_string,
	$region,
	$out_dir,
  $out_file,
	$tabix,
	$vcftools_dir,
	$vcftools,
	$vcf_subset,
	$vcf_fill_an_ac,
	$no_tabix,
	$help,
	%result_hash,
);
	
&GetOptions( 
	'vcf=s'					=> \$vcf,
	'sample_panel=s'		=> \$sample_panel,
	'pop=s'					=> \$user_input_pop_string,
	'region=s'				=> \$region,
	'out_dir:s'				=> \$out_dir,
	'tabix=s'				=> \$tabix,
	'vcftools_dir=s'		=> \$vcftools_dir,
  'out_file:s'  => \$out_file,
	'no_tabix!'				=> \$no_tabix,
	'help!'					=> \$help,
);

if ($help) {
	 exec('perldoc', $0);
}

if (!$region && !$no_tabix) {
	die("Please specify chromosome region. If the input VCF contains small number of sites, please use -no_tabix if you don't want to specify chromosome region\n");
}	 

if($no_tabix){
  unless(-e $vcf){
    die($vcf." must exist if tabix is not being run");
  }
}


	 	
#$tabix = "/nfs/1000g-work/G1K/work/bin/tabix/tabix" if (!$tabix);
#$vcftools_dir = "/nfs/1000g-work/G1K/work/bin/vcftools" if (!$vcftools_dir);
$tabix = "/localsw/bin/htslib-1.3.1/tabix";#"/nfs/public/rw/ensembl/tools/tabix/tabix";
$vcftools_dir = "/localsw/tools/vcftools/" if (!$vcftools_dir); #"/nfs/public/rw/ensembl/tools/vcftools"


$vcftools = "perl " . $vcftools_dir . "/bin/vcftools";
$vcf_subset = "perl " . $vcftools_dir . "/perl/vcf-subset";
$vcf_fill_an_ac = "perl " . $vcftools_dir . "/perl/fill-an-ac";

my $panel_hash = parse_sample_panel($sample_panel);

if ( (defined $user_input_pop_string && $user_input_pop_string =~ /ALL/i) || !$user_input_pop_string) {
	foreach my $pop (keys %$panel_hash ) {
		process(join(",", @{$panel_hash->{$pop}}), $pop);
	}	
	print_hash(\%result_hash, "all");
}

else {
	my @user_input_pops = split(/,/, $user_input_pop_string);
	foreach my $pop (keys %$panel_hash ) {
		foreach my $user_pop (@user_input_pops) {
			$user_pop =~ s/^\s+|\s+$//;
			if ($pop =~ /$user_pop/i) {
				process(join(",", @{$panel_hash->{$pop}}), $user_pop);
			}
		}	
	}	
	print_hash(\%result_hash, $user_input_pop_string);  
}	


####################
###### SUBS ########
####################
sub process {
	my ( $samples_string, $population )= @_;
	
	my $cmd;
	if ($no_tabix) {
		$cmd = "$vcf_subset -c $samples_string $vcf | $vcf_fill_an_ac | cut -f1-8";
	}
	else {
		$cmd = "$tabix -f -h $vcf $region | $vcf_subset -c $samples_string | $vcf_fill_an_ac | cut -f1-8";
	}
	open(CMD, $cmd." | ") or die("Failed to open ".$cmd." $!");

	while(<CMD>){
	  next if(/\#/);
	  chomp;
	  
	  my @values = split /\t/, $_;
	  my @info = split /\;/, $values[7];
	  
	  my $ac;
	  my $an; 
	  my $af = 0;

	  my $alt_alleles = $values[4];
	  
	  foreach my $info(@info){
	    if($info =~ /^AC/){
	      my ($tag, $num) = split /\=/, $info;
	      $ac = $num;
	    }
	    if($info =~ /^AN/){
	      my ($tag, $num) = split /\=/, $info;
	      $an = $num;
	    }
	  }
	  
	  if(!defined($ac)){
	    die("Failed to find ac from ".join("\t", $values[7]));
	  }
	  if(!$an){
	    die("Failed to find an from ".join("\t", $values[7]));
	  }
	  
	  #multiple alleles
	  if($ac =~ m/,/){
	    #$cmd can return multiple alleles in varying order T,A or A,T, for example
	    #need to account for this for combining populations in output
	    
	    #first, have we seen this site already?
	    my $site_and_ref = join ("\t", $values[0], $values[1],$values[2],$values[3]);
	    #if we have seen this before
	    if(/^$site_and_ref.*/ ~~ %result_hash){
		#make sure we have only one match
		my @site_match = grep /^$site_and_ref.*/, keys %result_hash;
		die("A multi-allelic site can't be distinguished from another site.\n") if scalar(@site_match) > 1;
		#get results hash alt allele string to use instead
		$alt_alleles = (split /\t/, $site_match[0])[4];
		#check alleles are the same
		my @result_alt_alleles = split /,/, $alt_alleles;
		my @curr_alt_alleles = split /,/, $values[4];
		@result_alt_alleles = sort { $a cmp $b } @result_alt_alleles;
		@curr_alt_alleles = sort { $a cmp $b } @curr_alt_alleles;
		die ("Different alt alleles.\n") if (!(@result_alt_alleles ~~ @curr_alt_alleles));
		# return to original orders
		@result_alt_alleles = split /,/, $alt_alleles;
		@curr_alt_alleles = split /,/, $values[4];
		my @ordered_acs;
		my @acs = split /,/, $ac;	
		#put new allele counts into same order as the result hash entry
		ALLELE: for (my $i = 0; $i < scalar(@result_alt_alleles); $i++){
		  for(my $j =0; $j < scalar(@curr_alt_alleles); $j++){
			if($result_alt_alleles[$i] eq $curr_alt_alleles[$j]){
			  $ordered_acs[$i] = $acs[$j];
			  next ALLELE;
			}	
		  }
		}
		#for each allele, now calc the frequency and put the output strings together
		my @afs;
		foreach my $ord_ac (@ordered_acs){
		  my $allele_freq = sprintf "%.2f", $ord_ac/$an;
		  push @afs, $allele_freq;
		}
		$af = join(",",@afs);
		$ac = join(",",@ordered_acs);
	    }
	    else{
		#multiple alleles but first time we've seen this site
		#just need to calc afs
		my @acs = split /,/, $ac;
		my @afs;
		foreach my $ind_ac (@acs){
		  my $allele_freq = sprintf "%.2f", $ind_ac/$an;
		  push @afs, $allele_freq;
		}		
		$af = join(",",@afs);
	    }
	  }
	  else{
		#not multiple alleles, so just do calc of AF
	  	$af = sprintf "%.2f", $ac/$an if($ac);
	  }	  
	  my $site_info = join ("\t", $values[0], $values[1],$values[2],$values[3], $alt_alleles);
	  my $site_stats = join ("\t", $an, $ac, $af);
	  
	  $result_hash{$site_info}{$population} = $site_stats;		
	}
	return 1;
}


sub parse_sample_panel {
	my ($panel_file) = @_;
	my %pop_sample_hash;
	
	my $fh;
	open($fh, "<", $panel_file) or die "Can't open '$panel_file': $!";
	while (<$fh>) {
		chomp;
		my $sample_line = $_;
		my ($sample, $pop_in_panel, $sup_pop, $platform) = split(/\t/, $sample_line);
		push @{$pop_sample_hash{$pop_in_panel}}, $sample;
	}
	return \%pop_sample_hash;
}	

sub print_hash {
	my ($hash, $p) = @_;
	
	my $out_h;
	my @pops;
	my %total_cnt_all_pops;
	my %alt_cnt_all_pops;
	
	$region =~ s/:/\./;
	#my $outfile = "$out_dir/calculated_fra.process$$" . "." . $region . "." . $p;
  my $outfile = $out_file ? $out_file : "$out_dir/calculated_fra.process" . "." . $region . "." . $p.".txt";
	$outfile =~ s/,/_/g;
	$outfile =~ s/\s+//;
	open ($out_h, ">", $outfile) || die("Cannot open output file $outfile");
	
	print $out_h "CHR\tPOS\tID\tREF\tALT\t";
	
	my %position_hash;
	foreach my $site (keys %{$hash}) {
		@pops = keys %{$hash->{$site}};
		$total_cnt_all_pops{$site} = 0;
		$alt_cnt_all_pops{$site} = 0;
		foreach my $p ( keys %{$hash->{$site}} ) {
			my @data = split(/\t/, $hash->{$site}->{$p});
			$total_cnt_all_pops{$site} += $data[0];
			if($data[1] =~ m/,/){#multiple alt alleles
			  if($alt_cnt_all_pops{$site} eq 0){
			    $alt_cnt_all_pops{$site} = $data[1];
			  }
			  else{
				my @curr_totals = split /,/, $alt_cnt_all_pops{$site};
				my @new_cnts = split /,/, $data[1];
				for(my $i=0; $i<scalar(@curr_totals);$i++){
				  $curr_totals[$i] = $curr_totals[$i] + $new_cnts[$i];
				}
				my $new_all_alt_cnt = join(",",@curr_totals);
				$alt_cnt_all_pops{$site} = $new_all_alt_cnt;
			  }
			}
			else{#not multiple alt alleles
			  $alt_cnt_all_pops{$site} += $data[1];
			}
		}
		my @meta_array = split(/\t/, $site);
		my $pos = $meta_array[0] . "." . $meta_array[1];
		$position_hash{$pos} = $site;
	}	
	
	my @sorted_positions = sort {$a<=>$b} keys %position_hash;
	
	if ( $p eq "all" ) {
		my @pop_header;
		push @pop_header, "ALL_POP_TOTAL_CNT", "ALL_POP_ALT_CNT", "ALL_POP_FRQ";
		foreach my $pop ( @pops ) {
			push @pop_header, $pop . "_TOTAL_CNT";
			
			push @pop_header, $pop . "_ALT_CNT";
			push @pop_header, $pop . "_FRQ";
		}
				
		print $out_h join ("\t",@pop_header) . "\n"; 		
		
		foreach my $site_pos (@sorted_positions) {
			my $site = $position_hash{$site_pos};		
			print $out_h "$site\t";
			print $out_h $total_cnt_all_pops{$site} . "\t" . $alt_cnt_all_pops{$site} . "\t";
			my $alt_afs_all_pops;
			if($alt_cnt_all_pops{$site} =~ m/,/){
			  #handle multi-allelic site
			  my @alt_cnts = split /,/, $alt_cnt_all_pops{$site};
			  my @alt_afs;
			  foreach my $alt_cnt (@alt_cnts){
				my $alt_af = sprintf "%.2f", $alt_cnt/$total_cnt_all_pops{$site};
				push @alt_afs, $alt_af;
			  }
			  $alt_afs_all_pops = join(',',@alt_afs);
			}
			else{
				$alt_afs_all_pops = sprintf "%.2f", $alt_cnt_all_pops{$site}/$total_cnt_all_pops{$site};
			}
			print $out_h $alt_afs_all_pops;
			print $out_h "\t";
			my @numbers;
			foreach my $pop_key ( keys %{$hash->{$site}} ) {
				push @numbers, $hash->{$site}->{$pop_key};
			}
			print $out_h join ("\t", @numbers) . "\n";
		}
	}
	else {
		my @user_pops = split(/,/, $p);	
		my @header;
		foreach my $user_p ( @user_pops) {
			$user_p =~ s/^\s+|\s+$//;
			push @header, $user_p . "_TOTAL_CNT";
			push @header, $user_p . "_ALT_CNT";
			push @header, $user_p . "_FRQ";
		}	
		
		print $out_h join ("\t", @header) . "\n";
		
		foreach my $site_pos (@sorted_positions) {
			my $site = $position_hash{$site_pos};	
			print $out_h "$site\t";
			my @numbers;
			foreach my $pop_key (@user_pops) {  ### this way the header population will match the numbers
				#print "pop is $pop_key\n";
				push @numbers, $hash->{$site}->{$pop_key};
			}
			print $out_h join ("\t", @numbers) . "\n";
		}
	}
	print STDERR $outfile."\n";
}		


=pod

=head1 NAME

calculate_allele_frq_from_vcf_file.pl

=head1 SYNOPSIS

This script takes a VCF file, a matching sample panel file, a chromosomal region, population names, it then calculates population-wide allele 
frequency for sites within the chromosomal region defined.

When no population is specified, allele fequences will be calcuated for all populations in the VCF files, one at a time.

=head1 Dependency

	To run this script, you need to install the following software
	tabix: http://sourceforge.net/projects/samtools/files/tabix/
	vcftools: http://sourceforge.net/projects/vcftools/files/
	
=head1 Options

	-vcf			Input VCF file that contains genotype data for each samples; this file must be bgzipped and tabix indexed; if '-no_tabix' is used, the 
vcf file can be uncompressed and un-indexed.
	-sample_panel	A tab deliminated file lists mapping between sample and population (see example below) 
	-pop			Populations of interest; separated by ",".  This field can be null
	-region			chromosome region of interest, format is chr_number:start_end (optional). 
	-out_dir		Where temporary file and final output files should be written to. Default is current direcotry.
	-tabix			A path to tabix executable
	-vcftools_dir	A path to the vcftools base directory that contains vcftools executable and perl libraries
	-no_tabix		If the input VCF files is a pre-sliced VCF file containing a small number of sites, this option can be used so the vcf file doesn't have 
					to be tabix indexed or bgzipped.  This is to speed up run time for the web application.
	-help			Print this page when specified

=head1 EXAMPLE lines from a sample panel file. Only the first 2 columns are essential.

	HG00096	GBR	EUR	ILLUMINA
	HG00097	GBR	EUR	ABI_SOLID
	HG00099	GBR	EUR	ABI_SOLID
	HG00100	GBR	EUR	ILLUMINA

=head1 OUTPUT

The allele frequency of an user-specified population for sites within the user-specified chromosomal region is written to a file.  The headers of the 
output file are:

	CHR:		Chromosome
	POS:		Start position of the variant
	ID:		Identification of the variant
	REF:		Reference allele
	ALT:		Alternative allele
	TOTAL_CNT:	Total number of alleles in samples of the chosen population(s) 
	ALT_CNT:	Number of alternative alleles observed in samples of the chosen populations(s)
	FRQ:		Ratio of ALT_CNT to TOTAL_CNT


=head1 EXAMPLE

perl $ZHENG_RP/bin/calculate_allele_frq_from_vcf.pl \
-vcf /nfs/1000g-archive/vol1/ftp/phase1/analysis_results/integrated_call_sets/ALL.chr22.integrated_phase1_v3.20101123.snps_indels_svs.genotypes.vcf.gz \
-out_dir ~ \
-sample_panel /nfs/1000g-archive/vol1/ftp/phase1/analysis_results/integrated_call_sets/integrated_call_samples.20101123.ALL.panel \
-region 22:17000000-17005000 \
-pop CEU,FIN \

OR (when the input VCF file is pre-sliced small size file)

perl $ZHENG_RP/bin/calculate_allele_frq_from_vcf.pl \
-vcf ALL.chr22_17000000_17005000.test.vcf \
-out_dir ~ \
-sample_panel /nfs/1000g-archive/vol1/ftp/phase1/analysis_results/integrated_call_sets/integrated_call_samples.20101123.ALL.panel \
-pop CEU,FIN \
-no_tabix 
