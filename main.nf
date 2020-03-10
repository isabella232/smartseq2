#!/usr/bin/env nextflow
/*
========================================================================================
                         nf-core/smartseq2
========================================================================================
 nf-core/smartseq2 Analysis Pipeline.
 #### Homepage / Documentation
 https://github.com/nf-core/smartseq2
----------------------------------------------------------------------------------------
*/

def helpMessage() {
    // TODO nf-core: Add to this help message with new command line parameters
    log.info nfcoreHeader()
    log.info"""

    Usage:

    The typical command for running the pipeline is as follows:

    nextflow run nf-core/smartseq2 --reads '*_R{1,2}.fastq.gz' -profile docker

    Mandatory arguments:
      --reads                       Path to input data (must be surrounded with quotes)
      -profile                      Configuration profile to use. Can use multiple (comma separated)
                                    Available: conda, docker, singularity, awsbatch, test and more.
                                    Conda does not work for the TraCeR and BraCeR steps.

    References:                     If not specified in the configuration file or you wish to overwrite any of the references.
      --genome                      Name of iGenomes reference
      --star_index                  Path to STAR index
      --gtf                         Path to gtf file
      --rsem_ref                    Path to RSEM reference
      --fasta                       Path to Fasta reference
      --species                     Species for TraCeR/BraCeR. Options are "Mmus" or "Hsap" for
                                    mouse or human data, respectively. Default: "Hsap"
      --save_reference              Save references generated by the pipeline to the 'reference' directory.

    Skip steps:
      --skip_fastqc                 Skip FastQC
      --skip_transcriptomics        Skip STAR alignment and both RSEM and featureCounts steps.
      --skip_rsem                   Skip the RSEM quantification step
      --skip_fc                     Skip the FeatureCounts quantification step
      --skip_tracer                 Skip the TraCeR T cell receptor reconstruction step
      --skip_bracer                 Skip the BraCeR T cell receptor reconstruction step

    Other options:
      --outdir                      The output directory where the results will be saved
      --publish_dir_mode            Specify how files are put into `outdir`.
                                    See https://www.nextflow.io/docs/latest/process.html#publishdir for all options.
      --email                       Set this parameter to your e-mail address to get a summary e-mail with details of the run sent to you when the workflow exits
      --max_multiqc_email_size      Theshold size for MultiQC report to be attached in notification email. If file generated by pipeline exceeds the threshold, it will not be attached (Default: 25MB)
      -name                         Name for the pipeline run. If not specified, Nextflow will automatically generate a random mnemonic.

    AWSBatch options:
      --awsqueue                    The AWSBatch JobQueue that needs to be set when running on AWSBatch
      --awsregion                   The AWS Region for your AWS Batch job to run on
    """.stripIndent()
}

/*
 * SET UP CONFIGURATION VARIABLES
 */

// Show help emssage
if (params.help){
    helpMessage()
    exit 0
}

// Check if genome exists in the config file
if (params.genomes && params.genome && !params.genomes.containsKey(params.genome)) {
    exit 1, "The provided genome '${params.genome}' is not available in the iGenomes file. Currently the available genomes are ${params.genomes.keySet().join(", ")}"
}

// Configurable reference genomes
fasta = params.genome ? params.genomes[ params.genome ].fasta ?: false : false
if ( params.fasta ){
    fasta = file(params.fasta)
    if( !fasta.exists() ) exit 1, "Fasta file not found: ${params.fasta}"
}

gtf = params.genome ? params.genomes[ params.genome ].gtf ?: false : false
if ( params.gtf ){
    gtf = file(params.gtf)
    if( !gtf.exists() ) exit 1, "GTF file not found: ${params.gtf}"
}
if ( !gtf && !(params.skip_fc || params.skip_transcriptomics)) {
    exit 1, "No GTF file provided. Specify either --genome or --gtf. "
}


// Has the run name been specified by the user?
//  this has the bonus effect of catching both -name and --name
custom_runName = params.name
if (!(workflow.runName ==~ /[a-z]+_[a-z]+/)) {
    custom_runName = workflow.runName
}

if (workflow.profile.contains('awsbatch')) {
    // AWSBatch sanity checking
    if (!params.awsqueue || !params.awsregion) exit 1, "Specify correct --awsqueue and --awsregion parameters on AWSBatch!"
    // Check outdir paths to be S3 buckets if running on AWSBatch
    // related: https://github.com/nextflow-io/nextflow/issues/813
    if (!params.outdir.startsWith('s3:')) exit 1, "Outdir not on S3 - specify S3 Bucket to run on AWSBatch!"
    // Prevent trace files to be stored on S3 since S3 does not support rolling files.
    if (params.tracedir.startsWith('s3:')) exit 1, "Specify a local tracedir or run without trace! S3 cannot be used for tracefiles."
}

// Stage config files
ch_multiqc_config = file("$baseDir/assets/multiqc_config.yaml", checkIfExists: true)
ch_multiqc_custom_config = params.multiqc_config ? Channel.fromPath(params.multiqc_config, checkIfExists: true) : Channel.empty()
ch_output_docs = file("$baseDir/docs/output.md", checkIfExists: true)

/*
 * Create a channel for input read files
 */
if(params.readPaths){
    Channel
        .from(params.readPaths)
        .map { row -> [ row[0], [file(row[1][0]), file(row[1][1])]] }
        .ifEmpty { exit 1, "params.readPaths was empty - no input files supplied" }
        .into { read_files_fastqc; read_files_star; read_files_bracer; read_files_tracer }
} else {
    Channel
        .fromFilePairs( params.reads, size: 2 )
        .ifEmpty { exit 1, "Cannot find any reads matching: ${params.reads}\nNB: Path needs to be enclosed in quotes!" }
        .into { read_files_fastqc; read_files_star; read_files_bracer; read_files_tracer }
}


// Header log info
log.info nfcoreHeader()
def summary = [:]
if(workflow.revision) summary['Pipeline Release'] = workflow.revision
summary['Run Name']         = custom_runName ?: workflow.runName
// TODO nf-core: Report custom parameters here
summary['Reads']            = params.reads
summary['Fasta Ref']        = params.fasta
summary["iGenome"]          = params.genome
summary["star_index"]       = params.star_index
summary["GTF file"]          = params.gtf
summary["RSEM ref"]         = params.rsem_ref
summary["Tracer/Bracer species"] = params.species
summary['Max Resources']    = "$params.max_memory memory, $params.max_cpus cpus, $params.max_time time per job"
if(workflow.containerEngine) summary['Container'] = "$workflow.containerEngine - $workflow.container"
summary['Output dir']       = params.outdir
summary['Launch dir']       = workflow.launchDir
summary['Working dir']      = workflow.workDir
summary['Script dir']       = workflow.projectDir
summary['User']             = workflow.userName
if (workflow.profile.contains('awsbatch')) {
    summary['AWS Region']   = params.awsregion
    summary['AWS Queue']    = params.awsqueue
    summary['AWS CLI']      = params.awscli
}
summary['Config Profile'] = workflow.profile
if (params.config_profile_description) summary['Config Description'] = params.config_profile_description
if (params.config_profile_contact)     summary['Config Contact']     = params.config_profile_contact
if (params.config_profile_url)         summary['Config URL']         = params.config_profile_url
if (params.email || params.email_on_fail) {
    summary['E-mail Address']    = params.email
    summary['E-mail on failure'] = params.email_on_fail
    summary['MultiQC maxsize']   = params.max_multiqc_email_size
}
log.info summary.collect { k,v -> "${k.padRight(18)}: $v" }.join("\n")
log.info "-\033[2m--------------------------------------------------\033[0m-"

// Check the hostnames against configured profiles
checkHostname()

Channel.from(summary.collect{ [it.key, it.value] })
    .map { k,v -> "<dt>$k</dt><dd><samp>${v ?: '<span style=\"color:#999999;\">N/A</a>'}</samp></dd>" }
    .reduce { a, b -> return [a, b].join("\n            ") }
    .map { x -> """
    id: 'nf-core-smartseq2-summary'
    description: " - this information is collected when the pipeline is started."
    section_name: 'nf-core/smartseq2 Workflow Summary'
    section_href: 'https://github.com/nf-core/smartseq2'
    plot_type: 'html'
    data: |
        <dl class=\"dl-horizontal\">
            $x
        </dl>
    """.stripIndent() }
    .set { ch_workflow_summary }


/***** END NF-CORE BOILERPLATE *******/
/***** START ACTUAL PIPELINE *********/



outdir = file(params.outdir)
mode = params.publish_dir_mode
species = params.species
if (fasta) {
    Channel.fromPath(fasta).into { fasta_star_idx; fasta_rsem_ref }
}
if (gtf) {
    Channel.fromPath(gtf).into { gtf_star_idx ; gtf_rsem_ref; gtf_feature_counts }
} 


/*
 * PREPROCESSING - Build STAR index
 */
if (!params.skip_transcriptomics) {
    if (!params.star_index && fasta) {
        process makeSTARindex {
            label 'high_memory'
            tag "$fasta"
            publishDir path: { params.save_reference ? "${params.outdir}/reference_genome" : params.outdir },
                        saveAs: { params.save_reference ? it : null }, mode: "$mode"

            input:
                file fasta from fasta_star_idx
                file gtf from gtf_star_idx

            output:
            file "star" into star_index

            script:
            def avail_mem = task.memory ? "--limitGenomeGenerateRAM ${task.memory.toBytes() - 100000000}" : ''
            """
            # unzip files if required
            FASTA=${fasta}
            GTF=${gtf}
            if [[ "${fasta}" == *".gz"* ]]; then
                gunzip -c ${fasta} > genome.fa
                FASTA=genome.fa
            fi
            if [[ "${gtf}" == *".gz"* ]]; then
                gunzip -c ${gtf} > annotation.gtf 
                GTF=annotation.gtf
            fi

            # make index
            mkdir star
            STAR \\
                --runMode genomeGenerate \\
                --runThreadN ${task.cpus} \\
                --sjdbGTFfile \$GTF \\
                --genomeDir star/ \\
                --genomeFastaFiles \$FASTA \\
                $avail_mem
            """
        }
    } else {
        star_index = Channel
            .fromPath(params.star_index, checkIfExists: true)
            .ifEmpty { exit 1, "STAR index not found: ${params.star_index}" }
    }
}


/**
 * PREPROCESSING - Build RSEM reference
 */
if (!params.skip_rsem && !params.skip_transcriptomics) {
    if (!params.rsem_ref && fasta && gtf) {
        process make_rsem_reference {
            label "mid_memory"
            publishDir path: { params.save_reference ? "${params.outdir}/reference_genome" : params.outdir },
                        saveAs: { params.save_reference ? it : null }, mode: "$mode"
            input:
                file fasta from fasta_rsem_ref
                file gtf from gtf_rsem_ref

            output:
                file "rsem" into rsem_ref

            script:
            """
            # unzip files if required
            FASTA=${fasta}
            GTF=${gtf}
            if [[ "${fasta}" == *".gz"* ]]; then
                gunzip -c ${fasta} > genome.fa
                FASTA=genome.fa
            fi
            if [[ "${gtf}" == *".gz"* ]]; then
                gunzip -c ${gtf} > annotation.gtf 
                GTF=annotation.gtf
            fi
            
            # make reference
            mkdir rsem
            rsem-prepare-reference --gtf \$GTF \$FASTA rsem/ref
            """
        }
    } else {
        rsem_ref = Channel
            .fromPath(params.rsem_ref, checkIfExists: true)
            .ifEmpty { exit 1, "RSEM reference not found: ${params.rsem_ref}" }
    }
}


/**
 * Step 1 - FastQC
 */
if (!params.skip_fastqc) {
    process fastqc {
        publishDir "$outdir/fastqc/${sample}_fastqc", mode: "$mode"
        input:
            set sample, file(in_fastq) from read_files_fastqc

        output:
            file("*.zip") into fastqc_files

        script:
        """
        fastqc  \
        -t ${task.cpus} \
        ${in_fastq.get(0)} \
        ${in_fastq.get(1)}
        """
    }
}


if (!params.skip_transcriptomics) {
    /**
    * Step 2 - STAR
    */
    process STAR {
        label "mid_memory"
        publishDir "$outdir/STAR/${sample_fq}_STAR", mode: "$mode"
        input:
            set sample_fq, file(in_fastq) from read_files_star
            file "star" from star_index.collect()

        output:
            set sample_fq, file("${sample_fq}.Aligned.sortedByCoord.out.bam") into bam_sort_filesgz
            set sample_fq, file("${sample_fq}.Aligned.toTranscriptome.out.bam") into bam_trans_filesgz
            set sample_fq, file("${sample_fq}.Log.final.out") into bam_mqc

        script:
        """
        TMP=""
        if [[ "${in_fastq.get(0)}" == *".gz"* ]]; then
            TMP="--readFilesCommand zcat"
        fi
        STAR --runThreadN ${task.cpus} --genomeDir star \$TMP \
                --readFilesIn ${in_fastq.get(0)} ${in_fastq.get(1)} \
                --outSAMtype BAM SortedByCoordinate --limitBAMsortRAM 16000000000 --outSAMunmapped Within \
                --twopassMode Basic --outFilterMultimapNmax 1 --quantMode TranscriptomeSAM \
                --outFileNamePrefix "${sample_fq}."
        """
    }


    /**
    * Step 3a - featureCounts
    */
    if(!params.skip_fc) {
        process featureCounts {
            publishDir "$outdir/featureCounts/$sample", mode: "$mode"
            input:
                set sample, file(bsort) from bam_sort_filesgz
                file anno_file from gtf_feature_counts.collect()

            output:
                file("*count.txt") into count_files1
                file("*count.txt") into count_files2
                file("*count.txt.summary") into count_mqc

            script:
            """
            featureCounts -t exon -T ${task.cpus} \
            -g gene_name \
            -a ${anno_file} \
            -o ${sample}.count.txt \
            ${bsort}

            """
        }

        /**
        * Step 5a summarize featureCounts
        */
        process summarize_FC {
            input:
                // do so in chunks, to avoid limit MAX_OPEN_FILES limit
                file x from count_files1.collate(100)

            output:
                file("*_resfc.txt") into result_files_fc

            script:
                """
                for fileid in $x
                do
                    name=`basename \${fileid} .count.txt`
                    echo \${name} > \${name}_fc.txt
                    grep -v "^#" \${fileid} | cut -f 7 | tail -n+2 >> \${name}_fc.txt
                done
                paste *_fc.txt > \${name}_resfc.txt

                """
        }

        /**
        * Step 6 - generate final count matrices
        * This additional step is required because of a failure with
        * "too many open files" when pasting all filese in one go. 
        */
        process make_matrices_fc {
            publishDir "$outdir/featureCounts", mode: "$mode"

            input:
                file x from result_files_fc.collect()
                file y from count_files2.collect()

            output:
                file("resultCOUNT.txt") into fc_cr

            script:
            """
            cut -f 1 ${y.get(0)} | grep -v "^#" > header_fc.txt
            paste header_fc.txt *_resfc.txt > resultCOUNT.txt
            """
        }

    } else {
        count_mqc = Channel.from(false)
    }


    /**
    * Step 3b - RSEM
    */
    if(!params.skip_rsem) {
        process rsem {
            publishDir "$outdir/RSEM/$sample_bam", mode: "$mode"
            input:
                set sample_bam, file(in_bam) from bam_trans_filesgz
                file "rsem" from rsem_ref.collect()

            output:
                file("*.genes.results") into tpm_files1
                file("*.genes.results") into tpm_files2
                file("*.stat") into rsem_mqc

            script:
            """
            REF_FILENAME=\$(basename rsem/*.grp)
            REF_NAME="\${REF_FILENAME%.*}"
            rsem-calculate-expression -p ${task.cpus} --paired-end \
            --bam \
            --estimate-rspd \
            --append-names \
            --output-genome-bam \
            ${in_bam} \
            rsem/\$REF_NAME \
            ${sample_bam}
            """
        }

        /**
        * Step 5b - summarize RSEM TPM
        */
        process summmarize_TPM {
            input:
                // do so in chunks, to avoid limit MAX_OPEN_FILES limit
                file y from tpm_files1.collate(100)

            output:
                file("*_restpm.txt") into result_files_tpm

            script:
            """
            for fileid in $y
            do
                name=`basename \${fileid} .genes.results`
                echo \${name} > \${name}_tpm.txt
                grep -v "^#" \${fileid} | cut -f 5 | tail -n+2 >> \${name}_tpm.txt
            done
            paste *_tpm.txt >> \${name}_restpm.txt
            """
        }
        
        /**
        * Step 6 - generate final count matrices
        * This additional step is required because of a failure with
        * "too many open files" when pasting all filese in one go. 
        */
        process make_matrices_tpm {
            publishDir "$outdir/RSEM", mode: "$mode"

            input:
                file z from result_files_tpm.collect()
                file a from tpm_files2.collect()

            output:
                file("resultTPM.txt") into tpm_cr

            script:
            """
            echo "ensemble_id\tgene_id" > header_tpm.txt
            cut -f 1 ${a.get(0)} | grep -v "^#" | tail -n+2 | sed "s/_/\t/" >> header_tpm.txt
            paste header_tpm.txt *_restpm.txt > resultTPM.txt
            """
        }

    } else {
        rsem_mqc = Channel.from(false)
    }
} else {
    rsem_mqc = Channel.from(false)
    count_mqc = Channel.from(false)
    bam_mqc = Channel.from(false)
}

/**
 * Step 4
 */
process multiqc {
    publishDir "$outdir/multiqc", mode: "$mode"

    input:
    file (mqc_custom_config) from ch_multiqc_custom_config.collect().ifEmpty([])
    file ('fastqc/*') from fastqc_files.collect().ifEmpty([])
    file ('star/*') from bam_mqc.collect().ifEmpty([])
    file ('featureCounts/*') from count_mqc.collect().ifEmpty([])
    file ('rsem/*') from rsem_mqc.collect().ifEmpty([])
    file ('software_versions/*') from ch_software_versions_yaml.collect()
    file workflow_summary from ch_workflow_summary.collectFile(name: "workflow_summary_mqc.yaml")

    output:
    file "multiqc_report.html" into multiqc_report
    file "multiqc_data"

    script:
    rtitle = custom_runName ? "--title \"$custom_runName\"" : ''
    rfilename = custom_runName ? "--filename " + custom_runName.replaceAll('\\W','_').replaceAll('_+','_') + "_multiqc_report" : ''
    custom_config_file = params.multiqc_config ? "--config $mqc_custom_config" : ''
    """
    multiqc -f $rtitle $rfilename $custom_config_file .
    """
}



if (!params.skip_tracer) {
    if (workflow.profile.contains("docker") || workflow.profile.contains("singularity")) {
        /**
        * Step 7 - run TraCeR
        */
        process TraCeR{
            label "tracer"
            publishDir "$outdir/TraCeR", mode: "$mode"

            input:
                set sample, file(in_tracer) from read_files_tracer

            output:
                file("*") into tcr_files

            script:
            """
            tracer assemble -p ${task.cpus} -s ${species} \
            ${in_tracer.get(0)} ${in_tracer.get(1)} ${sample} .
            """
        }


        /**
        * Step 8 - summarize TraCeR results
        */
        process TCR_summary{
            label "tracer"
            publishDir "$outdir/TraCeR", mode: "$mode"

            input:
                file ('*') from tcr_files.collect()

            output:
                file("filtered_TCRAB_summary/*")

            script:
            """
            tracer summarize -s ${species} .
            """
        }
    } else {
        exit 1, "Tracer requires Docker or Singularity. Run with -profile=docker or -profile=singularity. "
    }
}


if (!params.skip_bracer) {
    if (workflow.profile.contains("docker") || workflow.profile.contains("singularity")) {
        /**
        * Step 9 - run BraCeR
        */
        process BraCeR{
            label "bracer"
            publishDir "$outdir/BraCeR", mode: "$mode"

            input:
                set sample, file(in_bracer) from read_files_bracer

            output:
                file("*") into bcr_files

            script:
            """
            bracer assemble -p ${task.cpus} -s ${species} \
            ${sample} . ${in_bracer.get(0)} ${in_bracer.get(1)}
            """
        }


        /**
        * Step 10 - summarize BraCeR results
        */
        process BCR_summary{
            label "bracer"
            publishDir "$outdir/BraCeR", mode: "$mode"

            input:
                file ('*') from bcr_files.collect()

            output:
                file("filtered_BCR_summary/*")

            script:
            """
            bracer summarize -s ${species} .
            """
        }
    } else {
        exit 1, "Bracer requires Docker or Singularity. Run with -profile=docker or -profile=singularity. "
    }
}


/***** END ACTUAL PIPELINE **************/
/***** START NF-CORE OUTPUT BOILERPLATE */



/*
 * FINAL STEP - Output Description HTML
 */
process output_documentation {
    publishDir "${params.outdir}/pipeline_info", mode: 'copy'

    input:
    file "output_docs.md" from ch_output_docs

    output:
    file "results_description.html"

    script:
    """
    pandoc output_docs.md -o results_description.html --self-contained --standalone
    """
}

/*
 * Parse software version numbers
 */
process get_software_versions {
    publishDir "${params.outdir}/pipeline_info", mode: 'copy',
        saveAs: { filename ->
                      if (filename.indexOf(".csv") > 0) filename
                      else null
                }

    output:
    file 'software_versions_mqc.yaml' into ch_software_versions_yaml
    file "software_versions.csv"

    script:
    // TODO nf-core: Get all tools to print their version number here
    """
    echo $workflow.manifest.version > v_pipeline.txt
    echo $workflow.nextflow.version > v_nextflow.txt
    fastqc --version > v_fastqc.txt
    multiqc --version > v_multiqc.txt
    scrape_software_versions.py &> software_versions_mqc.yaml
    markdown_to_html.py $output_docs -o results_description.html
    """
}

/*
 * Completion e-mail notification
 */
workflow.onComplete {

    // Set up the e-mail variables
    def subject = "[nf-core/smartseq2] Successful: $workflow.runName"
    if (!workflow.success) {
        subject = "[nf-core/smartseq2] FAILED: $workflow.runName"
    }
    def email_fields = [:]
    email_fields['version'] = workflow.manifest.version
    email_fields['runName'] = custom_runName ?: workflow.runName
    email_fields['success'] = workflow.success
    email_fields['dateComplete'] = workflow.complete
    email_fields['duration'] = workflow.duration
    email_fields['exitStatus'] = workflow.exitStatus
    email_fields['errorMessage'] = (workflow.errorMessage ?: 'None')
    email_fields['errorReport'] = (workflow.errorReport ?: 'None')
    email_fields['commandLine'] = workflow.commandLine
    email_fields['projectDir'] = workflow.projectDir
    email_fields['summary'] = summary
    email_fields['summary']['Date Started'] = workflow.start
    email_fields['summary']['Date Completed'] = workflow.complete
    email_fields['summary']['Pipeline script file path'] = workflow.scriptFile
    email_fields['summary']['Pipeline script hash ID'] = workflow.scriptId
    if (workflow.repository) email_fields['summary']['Pipeline repository Git URL'] = workflow.repository
    if (workflow.commitId) email_fields['summary']['Pipeline repository Git Commit'] = workflow.commitId
    if (workflow.revision) email_fields['summary']['Pipeline Git branch/tag'] = workflow.revision
    email_fields['summary']['Nextflow Version'] = workflow.nextflow.version
    email_fields['summary']['Nextflow Build'] = workflow.nextflow.build
    email_fields['summary']['Nextflow Compile Timestamp'] = workflow.nextflow.timestamp

    def mqc_report = null
    try {
        if (workflow.success) {
            mqc_report = ch_multiqc_report.getVal()
            if (mqc_report.getClass() == ArrayList) {
                log.warn "[nf-core/smartseq2] Found multiple reports from process 'multiqc', will use only one"
                mqc_report = mqc_report[0]
            }
        }
    } catch (all) {
        log.warn "[nf-core/smartseq2] Could not attach MultiQC report to summary email"
    }

    // Check if we are only sending emails on failure
    email_address = params.email
    if (!params.email && params.email_on_fail && !workflow.success) {
        email_address = params.email_on_fail
    }

    // Render the TXT template
    def engine = new groovy.text.GStringTemplateEngine()
    def tf = new File("$baseDir/assets/email_template.txt")
    def txt_template = engine.createTemplate(tf).make(email_fields)
    def email_txt = txt_template.toString()

    // Render the HTML template
    def hf = new File("$baseDir/assets/email_template.html")
    def html_template = engine.createTemplate(hf).make(email_fields)
    def email_html = html_template.toString()

    // Render the sendmail template
    def smail_fields = [ email: email_address, subject: subject, email_txt: email_txt, email_html: email_html, baseDir: "$baseDir", mqcFile: mqc_report, mqcMaxSize: params.max_multiqc_email_size.toBytes() ]
    def sf = new File("$baseDir/assets/sendmail_template.txt")
    def sendmail_template = engine.createTemplate(sf).make(smail_fields)
    def sendmail_html = sendmail_template.toString()

    // Send the HTML e-mail
    if (email_address) {
        try {
            if (params.plaintext_email) { throw GroovyException('Send plaintext e-mail, not HTML') }
            // Try to send HTML e-mail using sendmail
            [ 'sendmail', '-t' ].execute() << sendmail_html
            log.info "[nf-core/smartseq2] Sent summary e-mail to $email_address (sendmail)"
        } catch (all) {
            // Catch failures and try with plaintext
            [ 'mail', '-s', subject, email_address ].execute() << email_txt
            log.info "[nf-core/smartseq2] Sent summary e-mail to $email_address (mail)"
        }
    }

    // Write summary e-mail HTML to a file
    def output_d = new File("${params.outdir}/pipeline_info/")
    if (!output_d.exists()) {
        output_d.mkdirs()
    }
    def output_hf = new File(output_d, "pipeline_report.html")
    output_hf.withWriter { w -> w << email_html }
    def output_tf = new File(output_d, "pipeline_report.txt")
    output_tf.withWriter { w -> w << email_txt }

    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_red = params.monochrome_logs ? '' : "\033[0;31m";
    c_reset = params.monochrome_logs ? '' : "\033[0m";

    if (workflow.stats.ignoredCount > 0 && workflow.success) {
        log.info "-${c_purple}Warning, pipeline completed, but with errored process(es) ${c_reset}-"
        log.info "-${c_red}Number of ignored errored process(es) : ${workflow.stats.ignoredCount} ${c_reset}-"
        log.info "-${c_green}Number of successfully ran process(es) : ${workflow.stats.succeedCount} ${c_reset}-"
    }

    if (workflow.success) {
        log.info "-${c_purple}[nf-core/smartseq2]${c_green} Pipeline completed successfully${c_reset}-"
    } else {
        checkHostname()
        log.info "-${c_purple}[nf-core/smartseq2]${c_red} Pipeline completed with errors${c_reset}-"
    }

}


def nfcoreHeader() {
    // Log colors ANSI codes
    c_black = params.monochrome_logs ? '' : "\033[0;30m";
    c_blue = params.monochrome_logs ? '' : "\033[0;34m";
    c_cyan = params.monochrome_logs ? '' : "\033[0;36m";
    c_dim = params.monochrome_logs ? '' : "\033[2m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_white = params.monochrome_logs ? '' : "\033[0;37m";
    c_yellow = params.monochrome_logs ? '' : "\033[0;33m";

    return """    -${c_dim}--------------------------------------------------${c_reset}-
                                            ${c_green},--.${c_black}/${c_green},-.${c_reset}
    ${c_blue}        ___     __   __   __   ___     ${c_green}/,-._.--~\'${c_reset}
    ${c_blue}  |\\ | |__  __ /  ` /  \\ |__) |__         ${c_yellow}}  {${c_reset}
    ${c_blue}  | \\| |       \\__, \\__/ |  \\ |___     ${c_green}\\`-._,-`-,${c_reset}
                                            ${c_green}`._,._,\'${c_reset}
    ${c_purple}  nf-core/smartseq2 v${workflow.manifest.version}${c_reset}
    -${c_dim}--------------------------------------------------${c_reset}-
    """.stripIndent()
}

def checkHostname() {
    def c_reset = params.monochrome_logs ? '' : "\033[0m"
    def c_white = params.monochrome_logs ? '' : "\033[0;37m"
    def c_red = params.monochrome_logs ? '' : "\033[1;91m"
    def c_yellow_bold = params.monochrome_logs ? '' : "\033[1;93m"
    if (params.hostnames) {
        def hostname = "hostname".execute().text.trim()
        params.hostnames.each { prof, hnames ->
            hnames.each { hname ->
                if (hostname.contains(hname) && !workflow.profile.contains(prof)) {
                    log.error "====================================================\n" +
                            "  ${c_red}WARNING!${c_reset} You are running with `-profile $workflow.profile`\n" +
                            "  but your machine hostname is ${c_white}'$hostname'${c_reset}\n" +
                            "  ${c_yellow_bold}It's highly recommended that you use `-profile $prof${c_reset}`\n" +
                            "============================================================"
                }
            }
        }
    }
}
