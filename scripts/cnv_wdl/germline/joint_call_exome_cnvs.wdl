version 1.0

import "../cnv_common_tasks.wdl" as CNVTasks
import "AnnotateChromosome.wdl" as AnnotateVcf
import "cnv_germline_case_scattered_workflow.wdl" as ScatterWorkflow

workflow JointCallExomeCNVs {

    ##################################
    #### required basic arguments ####
    ##################################
    input {
      Int num_samples_per_scatter_block
      #sample-specific arguments
      File contig_ploidy_calls_tar
      Array[File]+ segments_vcfs
      Array[File]+ segments_vcf_indexes
      Array[File]+ intervals_vcf
      Array[File]+ intervals_vcf_indexes
      Array[Array[File]] gcnv_calls_tars

      #model-specific arguments
      File intervals
      File? blacklist_intervals
      Array[File] gcnv_model_tars
      Array[File] calling_configs
      Array[File] denoising_configs
      Array[File] gcnvkernel_version
      Array[File] sharded_interval_lists
      File contig_ploidy_calls_tar
      Array[String]? allosomal_contigs
      Int ref_copy_number_autosomal_contigs
      File ref_fasta_dict
      File ref_fasta_fai
      File ref_fasta
      String x_contig_name
      File  protein_coding_gtf
      File  linc_rna_gtf
      File  promoter_bed
      File  noncoding_bed
      String gatk_docker
      String gatk_docker_clustering
      String sv_pipeline_docker
    }

    call MakePedFile {
      input:
        contig_ploidy_calls_tar = contig_ploidy_calls_tar,
        x_contig_name = x_contig_name
    }

    call ScatterWorkflow.SplitInputArray as SplitSegmentsVcfsList {
        input:
            input_array = segments_vcfs,
            num_inputs_in_scatter_block = num_samples_per_scatter_block,
            gatk_docker = gatk_docker
    }

    call ScatterWorkflow.SplitInputArray as SplitSegmentsIndexesList {
        input:
            input_array = segments_vcf_indexes,
            num_inputs_in_scatter_block = num_samples_per_scatter_block,
            gatk_docker = gatk_docker
    }

    Array[Array[String]] split_segments = SplitSegmentsVcfsList.split_array
    Array[Array[String]] split_segments_indexes = SplitSegmentsIndexesList.split_array

    if (length(split_segments) > 1) {
      scatter (subarray_index in range(length(split_segments))) {
        call JointSegmentation as ScatterJointSegmentation {
          input:
            segments_vcfs = split_segments[subarray_index],
            segments_vcf_indexes = split_segments_indexes[subarray_index],
            ped_file = MakePedFile.ped_file,
            ref_fasta = ref_fasta,
            ref_fasta_fai = ref_fasta_fai,
            ref_fasta_dict = ref_fasta_dict,
            gatk_docker = gatk_docker_clustering,
            model_intervals = intervals
        }
      }
    }

    call JointSegmentation as GatherJointSegmentation {
      input:
        segments_vcfs = select_first([flatten(ScatterJointSegmentation.segments_vcfs), segments_vcfs]),
        segments_vcf_indexes = select_first([flatten(ScatterJointSegmentation.segments_vcf_indexes), segments_vcfs]),
        ped_file = MakePedFile.ped_file,
        ref_fasta = ref_fasta,
        ref_fasta_fai = ref_fasta_fai,
        ref_fasta_dict = ref_fasta_dict,
        gatk_docker = gatk_docker_clustering,
        model_intervals = intervals
    }

    Array[Array[File]] gcnv_calls_tars_T = transpose(gcnv_calls_tars)

    scatter (scatter_index in range(length(segments_vcfs))) {
      call CNVTasks.PostprocessGermlineCNVCalls as RecalcQual {
        input:
              entity_id = sub(sub(basename(intervals_vcf[scatter_index]), ".vcf.gz", ""), "intervals_output_", ""),
              gcnv_calls_tars = gcnv_calls_tars_T[scatter_index],
              gcnv_model_tars = gcnv_model_tars,
              calling_configs = calling_configs,
              denoising_configs = denoising_configs,
              gcnvkernel_version = gcnvkernel_version,
              sharded_interval_lists = sharded_interval_lists,
              contig_ploidy_calls_tar = contig_ploidy_calls_tar,
              allosomal_contigs = allosomal_contigs,
              ref_copy_number_autosomal_contigs = ref_copy_number_autosomal_contigs,
              sample_index = scatter_index,
              intervals_vcf = intervals_vcf[scatter_index],
              intervals_vcf_index = intervals_vcf_indexes[scatter_index],
              clustered_vcf = GatherJointSegmentation.clustered_vcf,
              clustered_vcf_index = GatherJointSegmentation.clustered_vcf_index,
              gatk_docker = gatk_docker_clustering
      }
    }

    call FastCombine {
      input:
        input_vcfs = RecalcQual.genotyped_segments_vcf,
        input_vcf_indexes = RecalcQual.genotyped_segments_vcf_index,
        sv_pipeline_docker = sv_pipeline_docker
    }

    # this annotates any vcf -- for exomes we can do all chromosomes at once
    call AnnotateVcf.AnnotateChromosome {
        input:
          prefix = "combined.annotated",
          vcf = FastCombine.combined_vcf,
          protein_coding_gtf = protein_coding_gtf,
          linc_rna_gtf = linc_rna_gtf,
          promoter_bed = promoter_bed,
          noncoding_bed = noncoding_bed,
          sv_pipeline_docker = sv_pipeline_docker
    }

    output {
      File combined_calls = FastCombine.combined_vcf
      File combined_calls_index = FastCombine.combined_vcf_index
    }
}

task MakePedFile {
  input {
    File contig_ploidy_calls_tar
    String x_contig_name
  }

  command <<<
    set -e
    tar -xf ~{contig_ploidy_calls_tar}
    WORKSPACE=$( basename ~{contig_ploidy_calls_tar} .tar.gz)

    for sample in $(ls -d -1 SAMPLE*)
    do
      sample_name=$(cat $sample/sample_name.txt)
      x_ploidy=$(grep ^X $sample/contig_ploidy.tsv | cut -f 2)
      printf "%s\t%s\t0\t0\t%s\t0\n" $sample_name $sample_name $x_ploidy >> cohort.ped
    done
    >>>

    output {
      File ped_file = "cohort.ped"
    }

    runtime {
      docker: "gatksv/sv-base-mini:b3af2e3"
      memory: "3000 MB"
      disks: "local-disk 100 SSD"
      cpu: 1
      preemptible: 2
    }
}

task JointSegmentation {
  input {
    Array[File] segments_vcfs
    Array[File] segments_vcf_indexes
    File ped_file
    File ref_fasta_dict
    File ref_fasta_fai
    File ref_fasta
    File model_intervals

     # Runtime parameters
    String gatk_docker
    Int? mem_gb
    Int? disk_space_gb
    Boolean use_ssd = false
    Int? cpu
    Int? preemptible_attempts
    }

    parameter_meta {
      segments_vcfs: {localization_optional: true}
      segments_vcf_indexes: {localization_optional: true}
    }

    Int machine_mem_mb = select_first([mem_gb, 2]) * 1000
    Int command_mem_mb = machine_mem_mb - 500

  #NOTE: output has to be gzipped to be read in by pyvcf in the next step
  command <<<
    set -e
    /gatk/gatk --java-options "-Xmx~{command_mem_mb}m" JointCNVSegmentation \
    -R ~{ref_fasta} -O clustered.vcf.gz -V ~{sep=' -V ' segments_vcfs} --disable-sequence-dictionary-validation --model-call-intervals ~{model_intervals} -ped ~{ped_file}
    >>>

    output {
      File clustered_vcf = "clustered.vcf.gz"
      File clustered_vcf_index = "clustered.vcf.gz.tbi"
    }

    runtime {
      docker: gatk_docker
      memory: machine_mem_mb + " MB"
      disks: "local-disk " + select_first([disk_space_gb, 40]) + if use_ssd then " SSD" else " HDD"
      cpu: select_first([cpu, 1])
      preemptible: select_first([preemptible_attempts, 2])
    }
}

task CombineVariants {
  input {
    Array[File] input_vcfs
    Array[File] input_vcf_indexes
    File ref_fasta
    File ref_fasta_fai
    File ref_fasta_dict
    Int? preemptible_tries
    Int? disk_size
    Float? mem_gb
  }

  command <<<
    java -jar -XX:GCTimeLimit=50 -XX:GCHeapFreeLimit=10 -Xms2000m \
          -jar /usr/gitc/GATK35.jar \
          -T CombineVariants -R ~{ref_fasta} \
          -V ~{sep=' -V ' input_vcfs} \
          -o combined.vcf
    >>>

  runtime {
    docker: "us.gcr.io/broad-gotc-prod/genomes-in-the-cloud:2.4.3-1564508330"
    preemptible: select_first([preemptible_tries, 2])
    memory: select_first([mem_gb, 3.5]) + " GiB"
    cpu: "1"
    disks: "local-disk " + select_first([disk_size, 50]) + " HDD"
  }

  output {
    File combined_vcf = "combined.vcf"
    File combined_vcf_index = "combined.vcf.idx"
  }
}

task FastCombine {
  input {
    Array[File] input_vcfs
    Array[File] input_vcf_indexes
    String sv_pipeline_docker
    Int? preemptible_tries
    Int? disk_size
    Float? mem_gb
  }

  command <<<
  #bcftools gets pissy if the indexes look older than their VCFs
  index_fofn=~{write_lines(input_vcf_indexes)}
  while read index; do touch $index; done < $index_fofn

  bcftools merge -l ~{write_lines(input_vcfs)} -o combined.vcf.gz -O z --threads 4 -m all -0

  tabix combined.vcf.gz
  >>>

  output {
    File combined_vcf = "combined.vcf.gz"
    File combined_vcf_index = "combined.vcf.gz.tbi"
  }

  runtime {
    docker: sv_pipeline_docker
    preemptible: select_first([preemptible_tries, 2])
    memory: select_first([mem_gb, 3.5]) + " GiB"
    cpu: "1"
    disks: "local-disk " + select_first([disk_size, 50]) + " HDD"
  }
}