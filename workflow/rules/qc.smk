rule build_decontamination_db:
    output:
        fasta=decontam_db / "remove_contam.fa.gz",
        metadata=decontam_db / "remove_contam.tsv",
    threads: 1
    resources:
        mem_mb=GB,
    params:
        script=scripts_dir / "download_tb_reference_files.pl",
        outdir=lambda wildcards, output: Path(output.fasta).parent,
    conda:
        str(env_dir / "decontam_db.yaml")
    log:
        rule_log_dir / "build_decontamination_db.log",
    shell:
        """
        perl {params.script} {params.outdir} &> {log}
        tmpfile=$(mktemp)
        sed 's/NTM\t0/NTM\t1/g' {output.metadata} > "$tmpfile"
        mv "$tmpfile" {output.metadata}
        """


rule index_decontam_db_minimap2:
    input:
        fasta=rules.build_decontamination_db.output.fasta,
    output:
        mm2_index=decontam_db / "remove_contam.fa.gz.map-ont.mmi",
    threads: 4
    resources:
        mem_mb=lambda wildcards, attempt: attempt * int(32 * GB),
    params:
        extras="-I 12G -x map-ont",
    log:
        rule_log_dir / "index_decontam_db_minimap2.log",
    conda:
        str(env_dir / "aln_tools.yaml")
    shell:
        """
        minimap2 {params.extras} \
            -t {threads} \
            -d {output.mm2_index} \
            {input.fasta} 2> {log}
        """


rule index_decontam_db_bwa:
    input:
        fasta=rules.build_decontamination_db.output.fasta,
    output:
        bwa_index=multiext(str(decontam_db / "remove_contam.fa.gz"), *BWA_EXTNS),
    threads: 4
    resources:
        mem_mb=lambda wildcards, attempt: attempt * int(32 * GB),
    log:
        rule_log_dir / "index_decontam_db_bwa.log",
    conda:
        str(env_dir / "aln_tools.yaml")
    shell:
        "bwa index {input.fasta} 2> {log}"


rule illumina_preprocessing:
    input:
        r1=illumina_dir / "{isolate}/{sample}_R1.fq.gz",
        r2=illumina_dir / "{isolate}/{sample}_R2.fq.gz",
    output:
        r1=results / "illumina/preprocessing/{isolate}/{sample}_R1.fq.gz",
        r2=results / "illumina/preprocessing/{isolate}/{sample}_R2.fq.gz",
        report=report(
            results / "illumina/preprocessing/{isolate}/{sample}.fastp.html",
            category="QC",
            caption=report_dir / "illumina_preprocessing.rst",
        ),
    threads: 4
    resources:
        mem_mb=lambda wildcards, attempt: attempt * int(4 * GB),
    log:
        rule_log_dir / "illumina_preprocessing/{isolate}/{sample}.log",
    container:
        containers["fastp"]
    params:
        opts="-z 6 -l 30 --cut_tail",
    shadow:
        "shallow"
    shell:
        """
        fastp --in1 {input.r1} --in2 {input.r2} --out1 {output.r1} --out2 {output.r2} \
          -w {threads} -h {output.report} 2> {log}
        """


rule map_nanopore_to_decontam_db:
    input:
        index=rules.index_decontam_db_minimap2.output.mm2_index,
        query=rules.combine_fastqs.output.fastq,
    output:
        bam=results / "mapped/{sample}.sorted.bam",
        index=results / "mapped/{sample}.sorted.bam.bai",
    threads: 8
    resources:
        mem_mb=lambda wildcards, attempt: attempt * int(16 * GB),
    params:
        map_extras="-aL2 -x map-ont",
    conda:
        str(env_dir / "aln_tools.yaml")
    log:
        rule_log_dir / "map_to_decontam_db/{sample}.log",
    shell:
        """
        (minimap2 {params.map_extras} -t {threads} {input.index} {input.query} | \
            samtools sort -@ {threads} -o {output.bam}) 2> {log}
        samtools index -@ {threads} {output.bam} &>> {log}
        """


rule filter_contamination:
    input:
        bam=rules.map_nanopore_to_decontam_db.output.bam,
        metadata=rules.build_decontamination_db.output.metadata,
    output:
        keep_ids=filtered_dir / "{sample}/keep.reads",
        contam_ids=filtered_dir / "{sample}/contaminant.reads",
        unmapped_ids=filtered_dir / "{sample}/unmapped.reads",
    threads: 1
    resources:
        mem_mb=lambda wildcards, attempt: attempt * GB,
    conda:
        str(env_dir / "filter.yaml")
    params:
        script=scripts_dir / "filter_contamination.py",
        extra="--verbose --ignore-secondary",
        outdir=lambda wildcards, output: Path(output.keep_ids).parent,
    log:
        rule_log_dir / "filter_contamination/{sample}.log",
    shell:
        """
        python {params.script} {params.extra} \
            -i {input.bam} \
            -m {input.metadata} \
            -o {params.outdir} 2> {log}
        """


rule extract_decontaminated_reads:
    input:
        reads=rules.map_nanopore_to_decontam_db.input.query,
        read_ids=rules.filter_contamination.output.keep_ids,
    output:
        reads=filtered_dir / "{sample}/{sample}.filtered.fq.gz",
    threads: 1
    resources:
        mem_mb=lambda wildcards, attempt: int(2 * GB) * attempt,
    log:
        rule_log_dir / "extract_decontaminated_reads/{sample}.log",
    container:
        containers["seqkit"]
    shell:
        "seqkit grep -o {output.reads} -f {input.read_ids} {input.reads} 2> {log}"


rule subsample_reads:
    input:
        reads=rules.extract_decontaminated_reads.output.reads,
    output:
        reads=subsample_dir / "{sample}/{sample}.subsampled.fq.gz",
    threads: 1
    resources:
        mem_mb=int(0.5 * GB),
    container:
        containers["rasusa"]
    params:
        covg=config["max_covg"],
        genome_size=config["genome_size"],
        seed=88,
    log:
        rule_log_dir / "subsample_reads/{sample}.log",
    shell:
        """
        rasusa -c {params.covg} \
            -g {params.genome_size} \
            -i {input.reads} \
            -o {output.reads} \
            -s {params.seed} 2> {log}
        """


rule generate_krona_input:
    input:
        bam=rules.map_nanopore_to_decontam_db.output.bam,
        metadata=rules.build_decontamination_db.output.metadata,
    output:
        krona_input=plot_dir / "krona/{sample}.krona.tsv",
    threads: 1
    resources:
        mem_mb=lambda wildcards, attempt: int(0.5 * GB) * attempt,
    conda:
        str(env_dir / "krona.yaml")
    params:
        script=scripts_dir / "generate_krona_input.py",
        extras="--ignore-secondary",
    log:
        rule_log_dir / "generate_krona_input/{sample}.log",
    shell:
        """
        python {params.script} {params.extras} \
            -i {input.bam} -m {input.metadata} -o {output.krona_input} 2> {log}
        """
