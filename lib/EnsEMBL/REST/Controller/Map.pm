package EnsEMBL::REST::Controller::Map;
use Moose;
use namespace::autoclean;
use Try::Tiny;
require EnsEMBL::REST;
EnsEMBL::REST->turn_on_jsonp(__PACKAGE__);

BEGIN { extends 'Catalyst::Controller::REST'; }

sub region : Chained('/') CaptureArgs(1) PathPart('map') {
  my ( $self, $c, $species) = @_;
  $c->{stash}->{species} = $species;
  try {
    $c->stash->{slice_adaptor} = $c->model('Registry')->get_adaptor( $species, 'Core', 'Slice' );
  }
  catch {
    $c->go( 'ReturnError', 'from_ensembl', [$_] ) 
  };
}


sub translation_GET {  }

sub translation: Chained('/') Args(2) PathPart('map/translation') ActionClass('REST') {
  my ($self, $c, $id, $region) = @_;
  $c->stash()->{id} = $id;
  my $translation = $c->model('Lookup')->find_object_by_stable_id($c, $id);
  my $ref = ref($translation);
  $c->go('ReturnError', 'custom', ["Expected a Bio::EnsEMBL::Translation object but got a $ref object back. Check your ID"]) if $ref ne 'Bio::EnsEMBL::Translation';
  my $transcript = $translation->transcript();
  my $mappings = $self->_map_transcript_coords($c, $transcript, $region, 'pep2genomic');
  $self->status_ok( $c, entity => { mappings => $mappings } );
}

sub cdna_GET {  }

sub cdna: Chained('/') Args(2) PathPart('map/cdna') ActionClass('REST') {
  my ($self, $c, $id, $region) = @_;
  $c->stash()->{id} = $id;
  my $transcript = $c->model('Lookup')->find_object_by_stable_id($c, $id);
  my $ref = ref($transcript);
  $c->go('ReturnError', 'custom', ["Expected a Bio::EnsEMBL::Transcript object but got a $ref object back. Check your ID"]) if $ref ne 'Bio::EnsEMBL::Transcript';
  my $mappings = $self->_map_transcript_coords($c, $transcript, $region, 'cdna2genomic');
  $self->status_ok( $c, entity => { mappings => $mappings } );
}

sub cds_GET {  }

sub cds: Chained('/') Args(2) PathPart('map/cds') ActionClass('REST') {
  my ($self, $c, $id, $region) = @_;
  $c->stash()->{id} = $id;
  my $transcript = $c->model('Lookup')->find_object_by_stable_id($c, $id);
  my $ref = ref($transcript);
  $c->go('ReturnError', 'custom', ["Expected a Bio::EnsEMBL::Transcript object but got a $ref object back. Check your ID"]) if $ref ne 'Bio::EnsEMBL::Transcript';
  my $mappings = $self->_map_transcript_coords($c, $transcript, $region, 'cds2genomic');
  $self->status_ok( $c, entity => { mappings => $mappings } );
}

sub _map_transcript_coords {
  my ($self, $c, $transcript, $region, $method) = @_;
  my ($start, $end) = $region =~ /^(\d+) (?:\.{2} | -) (\d+)$/xms;
  if(!$start) {
    $c->go('ReturnError', 'custom', ["Region did not correctly parse. Please check documentation"]);
  }
  $start ||= $end;
  my $mapped = [$transcript->get_TranscriptMapper()->$method($start, $end)];
  return $self->map_mappings($c, $mapped);
}

sub get_region_slice : Chained("region") PathPart("") CaptureArgs(2) {
  my ( $self, $c, $old_assembly, $region ) = @_;
  my ($old_sr_name, $old_start, $old_end, $old_strand) = $c->model('Lookup')->decode_region($c, $region);
  $c->log->info($region);
  my $old_slice = try {
    $c->stash->{slice_adaptor}->fetch_by_region('chromosome', $old_sr_name, $old_start, $old_end, $old_strand, $old_assembly);
  }
  catch {
    $c->go('ReturnError', 'from_ensembl', [$_]);
  };
  # Get a slice for the old region (the region in the input file).
  $c->stash->{old_slice} = $old_slice;
}

sub mapped_region_data : Chained('get_region_slice') PathPart('') Args(1) ActionClass('REST') {
    my ( $self, $c, $target_assembly ) = @_;
    $c->stash->{target_assembly} = $target_assembly;
}

sub mapped_region_data_GET {
  my ( $self, $c ) = @_;
  $c->forward('map_data');
  $self->status_ok( $c, entity => { mappings => $c->stash->{mapped_data} } );
}

sub map_data : Private {
  my ( $self, $c ) = @_;
  my $old_slice   = $c->stash->{old_slice};
  my $old_cs_name = $old_slice->coord_system_name();
  my $old_sr_name = $old_slice->seq_region_name();
  my $old_start   = $old_slice->start();
  my $old_end     = $old_slice->end();
  my $old_strand  = $old_slice->strand();
  my $old_version = $old_slice->coord_system()->version();

  my @decoded_segments;
  try {
    my $projection = $old_slice->project('chromosome', $c->stash->{target_assembly});

    foreach my $segment ( @{$projection} ) {
      my $mapped_slice = $segment->to_Slice;
      my $mapped_data = {
        original => {
          coordinate_system => $old_cs_name,
          assembly => $old_version,
          seq_region_name => $old_sr_name,
          start => ($old_start + $segment->from_start() - 1),
          end => ($old_start + $segment->from_end() - 1),
          strand => $old_strand,
        },
        mapped => {
          coordinate_system => $mapped_slice->coord_system->name,
          assembly => $mapped_slice->coord_system->version,
          seq_region_name => $mapped_slice->seq_region_name(),
          start => $mapped_slice->start(),
          end => $mapped_slice->end(),
          strand => $mapped_slice->strand(),
        },
      };
      push(@decoded_segments, $mapped_data);
    }
  }
  catch {
    $c->go('ReturnError', 'from_ensembl', [$_]);
  };
  
  $c->stash(mapped_data => \@decoded_segments);
}

sub map_mappings {
  my ($self, $c, $mapped) = @_;
  my @r;
  foreach my $m (@{$mapped}) {
    my $strand = 0;
    my $gap = 0;
    if($m->isa('Bio::EnsEMBL::Mapper::Gap')) {
      $gap = 1;
    }
    else {
      $strand = $m->strand();
    }
    push(@r, {
      start => $m->start(),
      end => $m->end(),
      strand => $strand,
      rank => $m->rank(),
      gap => $gap,
    });
  }
  return \@r;
}

__PACKAGE__->meta->make_immutable;

1;