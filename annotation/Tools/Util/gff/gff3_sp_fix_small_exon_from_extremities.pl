#!/usr/bin/env perl

use Carp;
use Clone 'clone';
use strict;
use File::Basename;
use Getopt::Long;
use Statistics::R;
use Pod::Usage;
use Data::Dumper;
use List::MoreUtils qw(uniq);
use Bio::Tools::GFF;
use Bio::DB::Fasta;
#use Bio::Seq;
use Bio::SeqIO;
use BILS::Handler::GFF3handler qw(:Ok);
use BILS::Handler::GXFhandler qw(:Ok);

my $header = qq{
########################################################
# BILS 2018 - Sweden                                   #  
# jacques.dainat\@nbis.se                               #
# Please cite NBIS (www.nbis.se) when using this tool. #
########################################################
};

my $outfile = undef;
my $gff = undef;
my $file_fasta=undef;
my $codonTableId=1;
my $SIZE_OPT=15;
my $verbose = undef;
my $help= 0;

my @copyARGV=@ARGV;
if ( !GetOptions(
    "help|h" => \$help,
    "gff=s" => \$gff,
    "fasta|fa|f=s" => \$file_fasta,
    "table|codon|ct=i" => \$codonTableId,
    "size|s=i" => \$SIZE_OPT,
    "v!" => \$verbose,
    "output|outfile|out|o=s" => \$outfile))

{
    pod2usage( { -message => 'Failed to parse command line',
                 -verbose => 1,
                 -exitval => 1 } );
}

# Print Help and exit
if ($help) {
    pod2usage( { -verbose => 2,
                 -exitval => 2,
                 -message => "$header\n" } );
}
 
if ( ! (defined($gff)) or !(defined($file_fasta)) ){
    pod2usage( {
           -message => "$header\nAt least 2 parameter is mandatory:\nInput reference gff file (--gff) and Input fasta file (--fasta)\n\n",
           -verbose => 0,
           -exitval => 1 } );
}

if($codonTableId<0 and $codonTableId>25){
  print "$codonTableId codon table is not a correct value. It should be between 0 and 25 (0,23 and 25 can be problematic !)\n";
}

######################
# Manage output file #
my $gffout;
#my $gffout4;
if ($outfile) {
open(my $fh, '>', $outfile) or die "Could not open file '$outfile' $!";
  $gffout= Bio::Tools::GFF->new(-fh => $fh, -gff_version => 3 );
}
else{
  $gffout = Bio::Tools::GFF->new(-fh => \*STDOUT, -gff_version => 3);
}

                #####################
                #     MAIN          #
                #####################


######################
### Parse GFF input #
my ($hash_omniscient, $hash_mRNAGeneLink) = slurp_gff3_file_JD({ input => $gff
                                                              });
print ("GFF3 file parsed\n");


####################
# index the genome #
my $db = Bio::DB::Fasta->new($file_fasta);
print ("Genome fasta parsed\n");

####################

#counters
my $exonCounter=0;
my $mrnaCounter=0;
my $geneCounter=0;


foreach my $primary_tag_key_level1 (keys %{$hash_omniscient->{'level1'}}){ # primary_tag_key_level1 = gene or repeat etc...
  foreach my $gene_id (keys %{$hash_omniscient->{'level1'}{$primary_tag_key_level1}}){
    
    my $gene_feature = $hash_omniscient->{'level1'}{$primary_tag_key_level1}{$gene_id};
    my $strand = $gene_feature->strand();
    print "gene_id = $gene_id\n" if $verbose;

    foreach my $primary_tag_key_level2 (keys %{$hash_omniscient->{'level2'}}){ # primary_tag_key_level2 = mrna or mirna or ncrna or trna etc...
      if ( exists_keys( $hash_omniscient, ('level2', $primary_tag_key_level2, $gene_id) ) ){
        my $rnaFix=undef;
        foreach my $level2_feature ( @{$hash_omniscient->{'level2'}{$primary_tag_key_level2}{$gene_id}}) {
         
          # get level2 id
          my $level2_ID = lc($level2_feature->_tag_value('ID'));       

          my $exonFix=undef;  
          if ( exists_keys( $hash_omniscient, ('level3', 'exon', $level2_ID) ) ){
            my @exon_sorted = sort {$a->start <=> $b->start} @{$hash_omniscient->{'level3'}{'exon'}{$level2_ID}};        
             
            my $number_exon=$#{$hash_omniscient->{'level3'}{'exon'}{$level2_ID}}+1;

            #####################
            #start with left exon
            my $left_exon = $exon_sorted[0];
            my $exon_size = ($left_exon->end - $left_exon->start +1);
            
            if($exon_size < $SIZE_OPT){

              my $original_exon_start = $left_exon->start;
              my $new_exon_start = $left_exon->start-($SIZE_OPT - $exon_size );
              
              #modify the exon start
              $left_exon->start($new_exon_start);
              $exonCounter++;
              $exonFix=1;

              print "left_exon start fixed\n" if $verbose;

              #take care of CDS if needed
              if ( exists_keys( $hash_omniscient, ('level3', 'cds', $level2_ID) ) ){
                my @cds_sorted = sort {$a->start <=> $b->start} @{$hash_omniscient->{'level3'}{'cds'}{$level2_ID}};
                
                #Check if the exon modification could affect the CDS
                if($original_exon_start == $cds_sorted[0]->start()){

                  my $original_cds_start = $original_exon_start;

                  #get the sequence
                  my $sequence = $db->seq( $gene_feature->seq_id() );
                  #get codon table 
                  my $codonTable = Bio::Tools::CodonTable->new( -id => $codonTableId);

                  #extract the codon
                  my $this_codon = substr( $sequence, $original_cds_start-1, 3);

                  if($strand eq "+" or $strand == "1"){
                     #Check if it is not terminal codon, otherwise we have to extend the CDS.
                    
                    if(! $codonTable->is_start_codon( $this_codon )){
                      print "first exon plus strand : this is not a start codon\n";exit;
                    }

                  }
                  if($strand eq "-" or $strand == "-1"){
                    #reverse complement
                    my $seqobj = Bio::Seq->new(-seq => $this_codon);
                    $this_codon = $seqobj->revcom()->seq;

                    #Check if it is not terminal codon, otherwise we have to extend the CDS.
                    if(! $codonTable->is_ter_codon( $this_codon )){
                      print "first exon minus strand : this is not a terminal codon\n";exit;
                    }
                  }
                }
              }

            }
            ################
            #then right exon
            if($number_exon > 1){
              
              my $right_exon =  $exon_sorted[$#exon_sorted];
              my $exon_size = ($right_exon->end - $right_exon->start +1);
             
              if($exon_size < $SIZE_OPT){
                
                my $original_exon_end = $right_exon->end;
                my $new_exon_end = $right_exon->end+($SIZE_OPT - $exon_size );

                #modify the exon end
                $right_exon->end($new_exon_end);
                $exonCounter++;
                $exonFix=1;

                print "right_exon end fixed\n" if $verbose;

                #take care of CDS if needed
                if ( exists_keys( $hash_omniscient, ('level3', 'cds', $level2_ID) ) ){
                  my @cds_sorted = sort {$a->start <=> $b->start} @{$hash_omniscient->{'level3'}{'cds'}{$level2_ID}};
                  
                  #Check if the exon modification could affect the CDS
                  if($original_exon_end == $cds_sorted[$#cds_sorted]->end()){

                    my $original_cds_end = $original_exon_end;

                    #get the sequence
                    my $sequence = $db->seq( $gene_feature->seq_id() );
                    #get codon table 
                    my $codonTable = Bio::Tools::CodonTable->new( -id => $codonTableId);

                    #extract the codon
                    my $this_codon = substr( $sequence, $original_cds_end-3, 3);

                    if($strand eq "+" or $strand == "1"){
                      print "last plus strand\n" if $verbose;
                       #Check if it is not terminal codon, otherwise we have to extend the CDS.
                      
                      if(! $codonTable->is_ter_codon( $this_codon )){

                        print "last exon plus strand : $this_codon is not a stop codon\n";exit;
                      }

                    }
                    if($strand eq "-" or $strand == "-1"){
                      print "last minus strand\n" if $verbose;

                      #reverse complement
                      my $seqobj = Bio::Seq->new(-seq => $this_codon);
                      $this_codon = $seqobj->revcom()->seq;

                      #Check if it is not terminal codon, otherwise we have to extend the CDS.
                      if(! $codonTable->is_start_codon( $this_codon )){
                        print "last exon minus strand : $this_codon is not a start codon\n";exit;
                      }
                    }
                  }
                }
              }
            }
          }
          if($exonFix){
            $mrnaCounter++;
          }
        }
        if($rnaFix){
          $geneCounter++;
        }
      }
    }
  }
}

_check_all_level2_positions($hash_omniscient,0); # review all the feature L2 to adjust their start and stop according to the extrem start and stop from L3 sub features.
_check_all_level1_positions($hash_omniscient,0); # Check the start and end of level1 feature based on all features level2.

#END
my $string_to_print="usage: $0 @copyARGV\n";
$string_to_print .="Results:\n";
$string_to_print .="nb gene affected: $geneCounter\n";
$string_to_print .="nb rna affected: $mrnaCounter\n";
$string_to_print .="nb exon affected: $exonCounter\n";
print $string_to_print;

print_omniscient($hash_omniscient, $gffout); #print result

print "Bye Bye.\n";
#######################################################################################################################
        ####################
         #     METHODS    #
          ################
           ##############
            ############
             ##########
              ########
               ######
                ####
                 ##

__END__
if ( !GetOptions(

    "table|codon|ct=i" => \$codonTableId,

=head1 NAME

gff3_fix_small_exon_from_extremities.pl -

The script aims to extend the small exons to make them longer.
When submitting annotation to ENA they expect exon size of 15 nt minimum. Currently we extend only the exon from extremities, otherwise we risk to break the predicted ORF.
/!\ Script under development. When we extend an exon and the CDS has to be extended too (because is was a partial CDS), we exit;


=head1 SYNOPSIS

    ./gff3_fix_small_exon_from_extremities.pl -gff=infile.gff --fasta genome.fa [ -o outfile ]
    ./gff3_fix_small_exon_from_extremities.pl --help

=head1 OPTIONS

=over 8

=item B<-gff>

Input GFF3 file that will be read

=item B<-fa> or B<--fasta>

Genome fasta file
The name of the fasta file containing the genome to work with.

=item B<--ct> or B<--table> or B<--codon>

This option allows specifying the codon table to use - It expects an integer (1 by default = standard)

=item B<--size> or B<-s>

Minimum exon size accepted in nucleotide. All exon below this size will be extended to this size. Default value = 15.

=item B<-o> , B<--output> , B<--out> or B<--outfile>

Output GFF file.  If no output file is specified, the output will be
written to STDOUT.

=item B<-v>

Verbose option, make it easier to follow what is going on for debugging purpose.

=item B<-h> or B<--help>

Display this helpful text.

=back

=cut
