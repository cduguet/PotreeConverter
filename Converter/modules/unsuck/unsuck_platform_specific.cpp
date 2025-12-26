
#include "unsuck.hpp"

#ifdef _WIN32
	#include "TCHAR.h"
	#include "pdh.h"
	#include "windows.h"
	#include "psapi.h"

// see https://stackoverflow.com/questions/63166/how-to-determine-cpu-and-memory-consumption-from-inside-a-process
MemoryData getMemoryData() {

	MemoryData data;

	{
		MEMORYSTATUSEX memInfo;
		memInfo.dwLength = sizeof(MEMORYSTATUSEX);
		GlobalMemoryStatusEx(&memInfo);
		DWORDLONG totalVirtualMem = memInfo.ullTotalPageFile;
		DWORDLONG virtualMemUsed = memInfo.ullTotalPageFile - memInfo.ullAvailPageFile;;
		DWORDLONG totalPhysMem = memInfo.ullTotalPhys;
		DWORDLONG physMemUsed = memInfo.ullTotalPhys - memInfo.ullAvailPhys;

		data.virtual_total = totalVirtualMem;
		data.virtual_used = virtualMemUsed;

		data.physical_total = totalPhysMem;
		data.physical_used = physMemUsed;

	}

	{
		PROCESS_MEMORY_COUNTERS_EX pmc;
		GetProcessMemoryInfo(GetCurrentProcess(), (PROCESS_MEMORY_COUNTERS*)&pmc, sizeof(pmc));
		SIZE_T virtualMemUsedByMe = pmc.PrivateUsage;
		SIZE_T physMemUsedByMe = pmc.WorkingSetSize;

		static size_t virtualUsedMax = 0;
		static size_t physicalUsedMax = 0;

		virtualUsedMax = max(virtualMemUsedByMe, virtualUsedMax);
		physicalUsedMax = max(physMemUsedByMe, physicalUsedMax);

		data.virtual_usedByProcess = virtualMemUsedByMe;
		data.virtual_usedByProcess_max = virtualUsedMax;
		data.physical_usedByProcess = physMemUsedByMe;
		data.physical_usedByProcess_max = physicalUsedMax;
	}


	return data;
}


void printMemoryReport() {

	auto memoryData = getMemoryData();
	double vm = double(memoryData.virtual_usedByProcess) / (1024.0 * 1024.0 * 1024.0);
	double pm = double(memoryData.physical_usedByProcess) / (1024.0 * 1024.0 * 1024.0);

	stringstream ss;
	ss << "memory usage: "
		<< "virtual: " << formatNumber(vm, 1) << " GB, "
		<< "physical: " << formatNumber(pm, 1) << " GB"
		<< endl;

	cout << ss.str();

}

void launchMemoryChecker(int64_t maxMB, double checkInterval) {

	auto interval = std::chrono::milliseconds(int64_t(checkInterval * 1000));

	thread t([maxMB, interval]() {

		static double lastReport = 0.0;
		static double reportInterval = 1.0;
		static double lastUsage = 0.0;
		static double largestUsage = 0.0;

		while (true) {
			auto memdata = getMemoryData();

			using namespace std::chrono_literals;
			std::this_thread::sleep_for(interval);
		}

	});
	t.detach();

}

static ULARGE_INTEGER lastCPU, lastSysCPU, lastUserCPU;
static int numProcessors;
static HANDLE self;
static bool initialized = false;

void init() {
	SYSTEM_INFO sysInfo;
	FILETIME ftime, fsys, fuser;

	GetSystemInfo(&sysInfo);
	// numProcessors = sysInfo.dwNumberOfProcessors;
	numProcessors = std::thread::hardware_concurrency();

	GetSystemTimeAsFileTime(&ftime);
	memcpy(&lastCPU, &ftime, sizeof(FILETIME));

	self = GetCurrentProcess();
	GetProcessTimes(self, &ftime, &ftime, &fsys, &fuser);
	memcpy(&lastSysCPU, &fsys, sizeof(FILETIME));
	memcpy(&lastUserCPU, &fuser, sizeof(FILETIME));

	initialized = true;
}

CpuData getCpuData() {
	FILETIME ftime, fsys, fuser;
	ULARGE_INTEGER now, sys, user;
	double percent;

	if (!initialized) {
		init();
	}

	GetSystemTimeAsFileTime(&ftime);
	memcpy(&now, &ftime, sizeof(FILETIME));

	GetProcessTimes(self, &ftime, &ftime, &fsys, &fuser);
	memcpy(&sys, &fsys, sizeof(FILETIME));
	memcpy(&user, &fuser, sizeof(FILETIME));
	percent = (sys.QuadPart - lastSysCPU.QuadPart) +
		(user.QuadPart - lastUserCPU.QuadPart);
	percent /= (now.QuadPart - lastCPU.QuadPart);
	percent /= numProcessors;
	lastCPU = now;
	lastUserCPU = user;
	lastSysCPU = sys;

	CpuData data;
	data.numProcessors = numProcessors;
	data.usage = percent * 100.0;

	return data;
}

#elif defined(__APPLE__) || defined(__linux__)

// Shared implementation for Unix-like systems (Linux, macOS)
// Note: sysinfo is Linux-specific, so we need conditional compilation for memory stats if we want detailed system-wide info.
// For now, we'll implement a basic version or specific versions as needed.

#if defined(__linux__)
#include "sys/types.h"
#include "sys/sysinfo.h"
#elif defined(__APPLE__)
#include <mach/mach.h>
#include <sys/sysctl.h>
#endif

#include "stdlib.h"
#include "stdio.h"
#include "string.h"

// ... (Existing Linux helper functions like parseLine can remain if useful, or be adapted)

#if defined(__linux__)
int parseLine(char* line){
    // This assumes that a digit will be found and the line ends in " Kb".
    int i = strlen(line);
    const char* p = line;
    
	while (*p < '0' || *p > '9'){
		p++;
	}
	
    line[i - 3] = '\0';
    i = atoi(p);
	
    return i;
}

int64_t getVirtualMemoryUsedByProcess(){ //Note: this value is in KB!
    FILE* file = fopen("/proc/self/status", "r");
    int64_t result = -1;
    char line[128];

    while (fgets(line, 128, file) != NULL){
        if (strncmp(line, "VmSize:", 7) == 0){
            result = parseLine(line);
            break;
        }
    }
    fclose(file);
	
	result = result * 1024;
	
    return result;
}

int64_t getPhysicalMemoryUsedByProcess(){ //Note: this value is in KB!
    FILE* file = fopen("/proc/self/status", "r");
    int64_t result = -1;
    char line[128];

    while (fgets(line, 128, file) != NULL){
        if (strncmp(line, "VmRSS:", 6) == 0){
            result = parseLine(line);
            break;
        }
    }
    fclose(file);
	
	result = result * 1024;
	
    return result;
}
#endif


MemoryData getMemoryData() {
	
	MemoryData data;
	
#if defined(__linux__)
	struct sysinfo memInfo;

	sysinfo (&memInfo);
	int64_t totalVirtualMem = memInfo.totalram;
	totalVirtualMem += memInfo.totalswap;
	totalVirtualMem *= memInfo.mem_unit;

	int64_t virtualMemUsed = memInfo.totalram - memInfo.freeram;
	virtualMemUsed += memInfo.totalswap - memInfo.freeswap;
	virtualMemUsed *= memInfo.mem_unit;
	
	int64_t totalPhysMem = memInfo.totalram;
	totalPhysMem *= memInfo.mem_unit;
	
	long long physMemUsed = memInfo.totalram - memInfo.freeram;
	physMemUsed *= memInfo.mem_unit;

	int64_t virtualMemUsedByMe = getVirtualMemoryUsedByProcess();
	int64_t physMemUsedByMe = getPhysicalMemoryUsedByProcess();

    data.virtual_total = totalVirtualMem;
    data.virtual_used = virtualMemUsed;
    data.physical_total = totalPhysMem;
    data.physical_used = physMemUsed;
    
#elif defined(__APPLE__)
    // macOS implementation
    struct mach_task_basic_info info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count) == KERN_SUCCESS) {
        data.virtual_usedByProcess = info.virtual_size;
        data.physical_usedByProcess = info.resident_size;
    }
    
    // System wide memory info on macOS (simplified)
    int64_t totalPhysMem = 0;
    int mib[2];
    mib[0] = CTL_HW;
    mib[1] = HW_MEMSIZE;
    size_t length = sizeof(int64_t);
    sysctl(mib, 2, &totalPhysMem, &length, NULL, 0);
    
    data.physical_total = totalPhysMem;
    // other fields might require more complex queries
#endif


	static int64_t virtualUsedMax = 0;
	static int64_t physicalUsedMax = 0;

	virtualUsedMax = std::max((int64_t)data.virtual_usedByProcess, virtualUsedMax);
	physicalUsedMax = std::max((int64_t)data.physical_usedByProcess, physicalUsedMax);

	{
		data.virtual_usedByProcess_max = virtualUsedMax;
		data.physical_usedByProcess_max = physicalUsedMax;
	}


	return data;
}


void printMemoryReport() {

	auto memoryData = getMemoryData();
	double vm = double(memoryData.virtual_usedByProcess) / (1024.0 * 1024.0 * 1024.0);
	double pm = double(memoryData.physical_usedByProcess) / (1024.0 * 1024.0 * 1024.0);

	stringstream ss;
	ss << "memory usage: "
		<< "virtual: " << formatNumber(vm, 1) << " GB, "
		<< "physical: " << formatNumber(pm, 1) << " GB"
		<< endl;

	cout << ss.str();

}

void launchMemoryChecker(int64_t maxMB, double checkInterval) {

	auto interval = std::chrono::milliseconds(int64_t(checkInterval * 1000));

	thread t([maxMB, interval]() {

		static double lastReport = 0.0;
		static double reportInterval = 1.0;
		static double lastUsage = 0.0;
		static double largestUsage = 0.0;

		while (true) {
			auto memdata = getMemoryData();

			using namespace std::chrono_literals;
			std::this_thread::sleep_for(interval);
		}

	});
	t.detach();

}

static int numProcessors;
static bool initialized = false;
static unsigned long long lastTotalUser, lastTotalUserLow, lastTotalSys, lastTotalIdle;

void init() {
	numProcessors = std::thread::hardware_concurrency();
	
#if defined(__linux__)
	FILE* file = fopen("/proc/stat", "r");
    fscanf(file, "cpu %llu %llu %llu %llu", &lastTotalUser, &lastTotalUserLow, &lastTotalSys, &lastTotalIdle);
    fclose(file);
#endif

	initialized = true;
}

double getCpuUsage(){
    double percent = 0.0;
#if defined(__linux__)
    FILE* file;
    unsigned long long totalUser, totalUserLow, totalSys, totalIdle, total;

    file = fopen("/proc/stat", "r");
    fscanf(file, "cpu %llu %llu %llu %llu", &totalUser, &totalUserLow, &totalSys, &totalIdle);
    fclose(file);

    if (totalUser < lastTotalUser || totalUserLow < lastTotalUserLow ||
        totalSys < lastTotalSys || totalIdle < lastTotalIdle){
        //Overflow detection. Just skip this value.
        percent = -1.0;
    }else{
        total = (totalUser - lastTotalUser)
			+ (totalUserLow - lastTotalUserLow)
			+ (totalSys - lastTotalSys);
        percent = total;
        total += (totalIdle - lastTotalIdle);
        percent /= total;
        percent *= 100;
    }

    lastTotalUser = totalUser;
    lastTotalUserLow = totalUserLow;
    lastTotalSys = totalSys;
    lastTotalIdle = totalIdle;
#endif

    return percent;
}

CpuData getCpuData() {
	
	if (!initialized) {
		init();
	}

	CpuData data;
	data.numProcessors = numProcessors;
	data.usage = getCpuUsage();

	return data;
}


#endif