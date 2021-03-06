
YUM:=$(shell which yum)
APT:=$(shell which apt-get)
HADOOP:=$(shell which hadoop)
MVN:=../dist/maven/bin/mvn
TOOLS=git gcc cmake pdsh
TEZ_VERSION=0.8.4-SNAPSHOT
TEZ_BRANCH=master
HIVE_VERSION=2.2.0-SNAPSHOT
HIVE_BRANCH=master
HDFS=$(shell id hdfs 2> /dev/null)
# try to build against local hadoop always
ifneq ($(HADOOP),)
	HADOOP_VERSION=$(shell hadoop version | grep "^Hadoop" | cut -f 2 -d' ')
else
	HADOOP_VERSION=2.6.0
endif
APP_PATH:=$(shell echo /user/$$USER/apps/`date +%Y-%b-%d`/)
HISTORY_PATH:=$(shell echo /user/$$USER/tez-history/build=`date +%Y-%b-%d`/)
INSTALL_ROOT:=$(shell echo $$PWD/dist/)
HIVE_CONF_DIR=/etc/hive/conf/
#override this in local.mk to point to jdbc jars etc 
#AUX_JARS_PATH=/home/gopal/postgres/*:/usr/share/java/*
HS2_PORT=10002
OFFLINE=false
REBASE=false
CLEAN=clean

-include local.mk

#ifneq ($(HDFS),)
#	AS_HDFS=sudo -u hdfs env PATH=$$PATH JAVA_HOME=$$JAVA_HOME HADOOP_HOME=$$HADOOP_HOME HADOOP_CONF_DIR=$$HADOOP_CONF_DIR bash
#else
	AS_HDFS=bash
#endif

git: 
ifneq ($(YUM),)
	which $(TOOLS) || yum -y install git-core \
	gcc gcc-c++ \
	pdsh \
	cmake \
	zlib-devel openssl-devel 
endif
ifneq ($(APT),)
	which $(TOOLS) || apt-get install -y git gcc g++ python man cmake zlib1g-dev libssl-dev 
endif

maven: 
	$(OFFLINE) || wget -c http://www.us.apache.org/dist/maven/maven-3/3.0.5/binaries/apache-maven-3.0.5-bin.tar.gz
	-- mkdir -p $(INSTALL_ROOT)/maven/
	tar -C $(INSTALL_ROOT)/maven/ --strip-components=1 -xzvf apache-maven-3.0.5-bin.tar.gz
	-- sed -i~ -e "/<profiles>/r vendor-repos.xml" $(INSTALL_ROOT)/maven/conf/settings.xml  

ant: 
	$(OFFLINE) || wget -c http://archive.apache.org/dist/ant/binaries/apache-ant-1.9.1-bin.tar.gz
	-- mkdir -p $(INSTALL_ROOT)/ant/
	tar -C $(INSTALL_ROOT)/ant/ --strip-components=1 -xzvf apache-ant-1.9.1-bin.tar.gz
	-- yum -y remove ant

protobuf: git 
	$(OFFLINE) || wget -c https://github.com/google/protobuf/releases/download/v2.5.0/protobuf-2.5.0.tar.bz2
	tar -xvf protobuf-2.5.0.tar.bz2
	test -f $(INSTALL_ROOT)/protoc/bin/protoc || \
	(cd protobuf-2.5.0; \
	./configure --prefix=$(INSTALL_ROOT)/protoc/; \
	make -j4; \
	make install -k)

clean-protobuf:
	rm -rf protobuf-2.5.0/

mysql: 
	$(OFFLINE) || wget -c http://repo1.maven.org/maven2/mysql/mysql-connector-java/5.1.29/mysql-connector-java-5.1.29.jar

tez: git maven protobuf
	test -d tez || git clone --branch $(TEZ_BRANCH) https://git-wip-us.apache.org/repos/asf/tez.git tez
	export PATH=$(INSTALL_ROOT)/protoc/bin:$(INSTALL_ROOT)/maven/bin/:$$PATH; \
	cd tez/; . /etc/profile; \
	$(MVN) $(CLEAN) package install -DskipTests -Dhadoop.version=$(HADOOP_VERSION) -Paws -Phadoop24 -P\!hadoop26 $$($(OFFLINE) && echo "-o");
	# for hadoop version < 2.4.0, use -P\!hadoop24 -P\!hadoop26

clean-tez:
	rm -rf tez

hive: tez-dist.tar.gz 
	test -d hive || git clone --branch $(HIVE_BRANCH) https://github.com/apache/hive
	cd hive; if $(REBASE); then (git stash; git clean -f -d; git pull --rebase;); fi
	cd hive; sed -i~ "s@<tez.version>.*</tez.version>@<tez.version>$(TEZ_VERSION)</tez.version>@" pom.xml
	# this was a stupid change
	#test "$(TEZ_VERSION)" != "0.4.0-incubating" && (cd hive; patch -p0 -f -i ../hive-tez-0.5.patch)
	export PATH=$(INSTALL_ROOT)/protoc/bin:$(INSTALL_ROOT)/maven/bin/:$(INSTALL_ROOT)/ant/bin:$$PATH; \
	cd hive/; . /etc/profile; \
	$(MVN) $(CLEAN) package -Denforcer.skip=true -DskipTests=true -Pdir -Pdist -Phadoop-2 -Dhadoop-0.23.version=$(HADOOP_VERSION) -Dbuild.profile=nohcat $$($(OFFLINE) && echo "-o");

clean-hive:
	rm -rf hive

dist-tez: tez 
	cp tez/tez-dist/target/tez-$(TEZ_VERSION).tar.gz tez-dist.tar.gz

dist-hive: mysql hive
	cp -t hive/packaging/target/apache-hive*/apache-hive*/lib/ mysql*.jar
	tar --exclude='hadoop-*.jar' --exclude='protobuf-*.jar' -C hive/packaging/target/apache-hive*/apache-hive*/ -czvf hive-dist.tar.gz .

tez-dist.tar.gz:
	@echo "run make dist to get tez-dist.tar.gz"

hive-dist.tar.gz:
	@echo "run make dist to get tez-dist.tar.gz"

dist: dist-tez dist-hive

tez-hiveserver-on:
	@cp scripts/startHiveserver2.sh.on /tmp/startHiveserver2.sh
	@echo "HiveServer2 will now run jobs using Tez."
	@echo "Reboot the Sandbox for changes to take effect."

tez-hiveserver-off:
	@cp scripts/startHiveserver2.sh.off /tmp/startHiveserver2.sh
	@echo "HiveServer2 will now run jobs using Map-Reduce."
	@echo "Reboot the Sandbox for changes to take effect."

install: tez-dist.tar.gz hive-dist.tar.gz
	rm -rf $(INSTALL_ROOT)/tez
	mkdir -p $(INSTALL_ROOT)/tez/conf
	tar -C $(INSTALL_ROOT)/tez/ -xzvf tez-dist.tar.gz
	cp -v tez-site.xml $(INSTALL_ROOT)/tez/conf/
	sed -i~ "s@/apps@$(APP_PATH)tez/tez-dist.tar.gz@g" $(INSTALL_ROOT)/tez/conf/tez-site.xml
	sed -i~ "s@/tez-history/@$(HISTORY_PATH)@g" $(INSTALL_ROOT)/tez/conf/tez-site.xml
	$(AS_HDFS) -c "hadoop fs -rm -R -f $(APP_PATH)/tez/"
	$(AS_HDFS) -c "hadoop fs -mkdir -p $(APP_PATH)/tez/"
	$(AS_HDFS) -c "hadoop fs -copyFromLocal -f tez-dist.tar.gz $(APP_PATH)/tez/"
	rm -rf $(INSTALL_ROOT)/hive
	mkdir -p $(INSTALL_ROOT)/hive
	tar -C $(INSTALL_ROOT)/hive -xzvf hive-dist.tar.gz
	(test -d $(HIVE_CONF_DIR) && rsync -avP $(HIVE_CONF_DIR)/ $(INSTALL_ROOT)/hive/conf/) \
	    || (cp hive-site.xml.default $(INSTALL_ROOT)/hive/conf/hive-site.xml && sed -i~ "s@HOSTNAME@$$(hostname)@" $(INSTALL_ROOT)/hive/conf/hive-site.xml)
	echo "export HADOOP_CLASSPATH=$(INSTALL_ROOT)/tez/*:$(INSTALL_ROOT)/tez/lib/*:$(INSTALL_ROOT)/tez/conf/:$$HADOOP_CLASSPATH:$(AUX_JARS_PATH)" >> $(INSTALL_ROOT)/hive/bin/hive-config.sh
	echo "export HADOOP_USER_CLASSPATH_FIRST=true" >> $(INSTALL_ROOT)/hive/bin/hive-config.sh
	(test -f $(INSTALL_ROOT)/hive/conf/hive-env.sh && sed -i~ "s@export HIVE_CONF_DIR=.*@export HIVE_CONF_DIR=$(INSTALL_ROOT)/hive/conf/@" $(INSTALL_ROOT)/hive/conf/hive-env.sh) \
		|| echo "export HIVE_CONF_DIR=$(INSTALL_ROOT)/hive/conf/" > $(INSTALL_ROOT)/hive/conf/hive-env.sh
	sed  -e "s/>10002</>$(HS2_PORT)</" \
	-e "s@hdfs:///user/hive/@$$\{fs.default.name\}$(APP_PATH)/hive/@" hive-site.xml.frag > hive-site.xml.local
	sed -i~ \
	-e "s/org.apache.hadoop.hive.ql.security.ProxyUserAuthenticator//" \
	-e "/<.configuration>/r hive-site.xml.local" \
	-e "x;" \
	$(INSTALL_ROOT)/hive/conf/hive-site.xml    
	$(AS_HDFS) -c "hadoop fs -rm -f $(APP_PATH)/hive/hive-exec-$(HIVE_VERSION).jar"
	$(AS_HDFS) -c "hadoop fs -mkdir -p $(APP_PATH)/hive/"
	$(AS_HDFS) -c "hadoop fs -copyFromLocal -f $(INSTALL_ROOT)/hive/lib/hive-exec-$(HIVE_VERSION).jar $(APP_PATH)/hive/"
	$(AS_HDFS) -c "hadoop fs -chmod -R a+r $(APP_PATH)/"
	# either log4j or log4j2
	(rename .xml.template .xml $(INSTALL_ROOT)/hive/conf/*log4j2.xml.template  && echo "log4j2 detected")\
		|| (rename .properties.template .properties $(INSTALL_ROOT)/hive/conf/*log4j.properties.template && echo "logj1 detected")

clean-dist:
	rm -rf $(INSTALL_ROOT)

clean-all: clean clean-tez clean-hive clean-protobuf

clean: clean-dist

.PHONY: hive tez protobuf ant maven
