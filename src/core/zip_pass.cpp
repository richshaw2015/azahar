// Copyright 2026 Azahar Emulator Project
// Licensed under GPLv2 or any later version
// Refer to the misc/licenses/gplv2.txt file included.

#include <chrono>
#include <cryptopp/osrng.h>
#include <cryptopp/zlib.h>
#include "common/common_paths.h"
#include "common/file_util.h"
#include "common/logging/log.h"
#include "common/settings.h"
#include "core/hle/kernel/shared_page.h"
#include "core/hle/service/cecd/cecd.h"
#include "core/system_titles.h"
#include "core/zip_pass.h"

namespace Core {

namespace {

constexpr u32 ZIP_LOCAL_MAGIC = 0x04034b50;
constexpr u32 ZIP_CENTRAL_MAGIC = 0x02014b50;
constexpr u32 ZIP_EOCD_MAGIC = 0x06054b50;
constexpr u16 ZIP_METHOD_STORED = 0;
constexpr u16 ZIP_METHOD_DEFLATE = 8;

#pragma pack(push, 1)
struct ZipLocalHeader {
    u32_le magic;
    u16_le version;
    u16_le flags;
    u16_le method;
    u16_le mod_time;
    u16_le mod_date;
    u32_le crc32;
    u32_le compressed_size;
    u32_le uncompressed_size;
    u16_le name_length;
    u16_le extra_length;
};

struct ZipCentralHeader {
    u32_le magic;
    u16_le version_made;
    u16_le version_needed;
    u16_le flags;
    u16_le method;
    u16_le mod_time;
    u16_le mod_date;
    u32_le crc32;
    u32_le compressed_size;
    u32_le uncompressed_size;
    u16_le name_length;
    u16_le extra_length;
    u16_le comment_length;
    u16_le disk_start;
    u16_le internal_attrs;
    u32_le external_attrs;
    u32_le local_offset;
};

struct ZipEocd {
    u32_le magic;
    u16_le disk;
    u16_le central_disk;
    u16_le entries_disk;
    u16_le entries_total;
    u32_le central_size;
    u32_le central_offset;
    u16_le comment_length;
};
#pragma pack(pop)

struct ZipWriter {
    FileUtil::IOFile file;
    std::vector<std::pair<std::string, ZipCentralHeader>> entries;
    u32 crc_table[256];

    ZipWriter(const std::string& path) : file(path, "wb") {
        for (u32 i = 0; i < 256; i++) {
            u32 c = i;
            for (int k = 0; k < 8; k++)
                c = (c & 1) ? (0xEDB88320 ^ (c >> 1)) : (c >> 1);
            crc_table[i] = c;
        }
    }

    u32 Crc(const u8* data, std::size_t size) const {
        u32 crc = 0xFFFFFFFF;
        for (std::size_t i = 0; i < size; i++)
            crc = crc_table[(crc ^ data[i]) & 0xFF] ^ (crc >> 8);
        return crc ^ 0xFFFFFFFF;
    }

    bool Add(const std::string& name, const u8* data, std::size_t size) {
        if (!file.IsOpen())
            return false;

        ZipLocalHeader header{};
        header.magic = ZIP_LOCAL_MAGIC;
        header.version = 20;
        header.method = ZIP_METHOD_STORED;
        header.crc32 = Crc(data, size);
        header.compressed_size = static_cast<u32>(size);
        header.uncompressed_size = static_cast<u32>(size);
        header.name_length = static_cast<u16>(name.size());

        ZipCentralHeader central{};
        central.magic = ZIP_CENTRAL_MAGIC;
        central.version_made = 20;
        central.version_needed = 20;
        central.method = ZIP_METHOD_STORED;
        central.crc32 = header.crc32;
        central.compressed_size = header.compressed_size;
        central.uncompressed_size = header.uncompressed_size;
        central.name_length = header.name_length;
        central.local_offset = static_cast<u32>(file.Tell());

        if (file.WriteBytes(&header, sizeof(header)) != sizeof(header) ||
            file.WriteBytes(name.data(), name.size()) != name.size() ||
            file.WriteBytes(data, size) != size) {
            return false;
        }

        entries.emplace_back(name, central);
        return true;
    }

    bool Finish() {
        if (!file.IsOpen())
            return false;

        const u32 central_offset = static_cast<u32>(file.Tell());
        for (const auto& [name, central] : entries) {
            if (file.WriteBytes(&central, sizeof(central)) != sizeof(central) ||
                file.WriteBytes(name.data(), name.size()) != name.size()) {
                return false;
            }
        }

        ZipEocd eocd{};
        eocd.magic = ZIP_EOCD_MAGIC;
        eocd.entries_disk = static_cast<u16>(entries.size());
        eocd.entries_total = static_cast<u16>(entries.size());
        eocd.central_size = static_cast<u32>(file.Tell()) - central_offset;
        eocd.central_offset = central_offset;

        if (file.WriteBytes(&eocd, sizeof(eocd)) != sizeof(eocd))
            return false;
        file.Close();
        return true;
    }
};

struct ZipReader {
    struct Entry {
        std::string name;
        u16 method;
        u32 compressed_size;
        u32 uncompressed_size;
        u32 local_offset;
    };

    FileUtil::IOFile file;
    std::vector<Entry> entries;

    explicit ZipReader(const std::string& path) : file(path, "rb") {
        if (!file.IsOpen())
            return;

        const u64 size = file.GetSize();
        if (size < sizeof(ZipEocd))
            return;

        // Scan backwards for the end-of-central-directory record.
        const u64 scan_size = std::min<u64>(size, 0x10000 + sizeof(ZipEocd));
        std::vector<u8> tail(scan_size);
        file.Seek(size - scan_size, SEEK_SET);
        if (file.ReadBytes(tail.data(), tail.size()) != tail.size())
            return;

        for (s64 i = static_cast<s64>(scan_size) - sizeof(ZipEocd); i >= 0; i--) {
            ZipEocd eocd;
            std::memcpy(&eocd, tail.data() + i, sizeof(eocd));
            if (eocd.magic != ZIP_EOCD_MAGIC)
                continue;

            if (eocd.central_offset >= size ||
                eocd.central_offset +
                        eocd.entries_total * static_cast<u64>(sizeof(ZipCentralHeader)) >
                    size) {
                return;
            }

            file.Seek(eocd.central_offset, SEEK_SET);
            for (u32 e = 0; e < eocd.entries_total; e++) {
                ZipCentralHeader central;
                if (file.ReadBytes(&central, sizeof(central)) != sizeof(central))
                    return;
                Entry entry{};
                entry.method = central.method;
                entry.compressed_size = central.compressed_size;
                entry.uncompressed_size = central.uncompressed_size;
                entry.local_offset = central.local_offset;
                if (central.name_length == 0 ||
                    file.Tell() + central.name_length + central.extra_length +
                            central.comment_length >
                        static_cast<s64>(size)) {
                    return;
                }
                entry.name.resize(central.name_length);
                if (file.ReadBytes(entry.name.data(), central.name_length) !=
                    central.name_length) {
                    return;
                }
                file.Seek(central.extra_length + central.comment_length, SEEK_CUR);
                entries.push_back(std::move(entry));
            }
            return;
        }
    }

    bool Read(const Entry& entry, std::vector<u8>& out) {
        ZipLocalHeader header;
        file.Seek(entry.local_offset, SEEK_SET);
        if (file.ReadBytes(&header, sizeof(header)) != sizeof(header) ||
            header.magic != ZIP_LOCAL_MAGIC) {
            return false;
        }
        file.Seek(header.name_length + header.extra_length, SEEK_CUR);

        if (entry.method == ZIP_METHOD_STORED) {
            out.resize(entry.uncompressed_size);
            return file.ReadBytes(out.data(), out.size()) == out.size();
        }
        if (entry.method == ZIP_METHOD_DEFLATE) {
            std::vector<u8> compressed(entry.compressed_size);
            if (file.ReadBytes(compressed.data(), compressed.size()) != compressed.size())
                return false;
            out.resize(entry.uncompressed_size);
            CryptoPP::Inflator inflator(nullptr, false, -15);
            inflator.Put(compressed.data(), compressed.size());
            inflator.MessageEnd();
            return inflator.Get(out.data(), out.size()) == out.size();
        }
        return false;
    }
};

int addFileToZip(ZipWriter& writer, const std::string& zipPath, const std::string& srcPath) {
    FileUtil::IOFile src(srcPath, "rb");
    if (!src.IsOpen())
        return -1;
    const u64 size = src.GetSize();
    std::vector<u8> data(size);
    if (size && src.ReadBytes(data.data(), size) != size)
        return -1;
    return writer.Add(zipPath, data.data(), data.size()) ? 0 : -1;
}

} // namespace

int exportZipPass(std::string path) {
    LOG_INFO(Frontend, "exportZipPass {}", path);

    ZipWriter writer(path);
    if (!writer.file.IsOpen())
        return -1;

    const auto callback = [&writer](u64* num_entries_out, const std::string& directory,
                                    const std::string& virtual_name) -> bool {
        const std::string physical_name = directory + DIR_SEP + virtual_name;
        if (FileUtil::IsDirectory(physical_name) && virtual_name.length() == 8) {
            const auto callback2 = [&writer, virtual_name](u64* num_entries_out,
                                                           const std::string& directory,
                                                           const std::string& v_name) -> bool {
                std::string real_name = directory + DIR_SEP + v_name;
                if (v_name[0] == '_' && v_name.length() == 12) {
                    addFileToZip(writer, virtual_name + "/" + v_name,
                                 FileUtil::SanitizePath(real_name));
                }
                return true;
            };

            FileUtil::ForeachDirectoryEntry(nullptr, physical_name + DIR_SEP + "OutBox__",
                                          callback2);
        }
        return true;
    };

    const std::string dir = FileUtil::GetUserPath(FileUtil::UserPath::NANDDir) + DIR_SEP + "data" +
                            DIR_SEP + "00000000000000000000000000000000" + DIR_SEP + "sysdata" +
                            DIR_SEP + "00010026" + DIR_SEP + "00000000" + DIR_SEP + "CEC";

    FileUtil::ForeachDirectoryEntry(nullptr, dir, callback);

    const int ret = static_cast<int>(writer.entries.size());
    if (!writer.Finish())
        return -1;

    return ret;
}

static int zipPassChecks() {
    int nHomes = 0;

    for (u32 region = 0; region < Core::NUM_SYSTEM_TITLE_REGIONS; region++) {
        if (region == 3)
            continue;
        const auto hpath = Core::GetHomeMenuNcchPath(region);

        if (!hpath.empty() && FileUtil::Exists(hpath)) {
            nHomes++;
        }
    }

    if (nHomes < 1) {
        LOG_ERROR(Frontend, "importZipPass impossible without system files");
        return -2;
    }

    if (!Settings::values.enable_required_online_lle_modules.GetValue()) {
        LOG_ERROR(Frontend, "importZipPass impossible without LLE modules");
        return -3;
    }

    return 0;
}

int importZipPass(std::string path) {
    LOG_INFO(Frontend, "importZipPass {}", path);

    int ret = zipPassChecks();
    if (ret)
        return ret;
    ret = 0;

    ZipReader reader(path);
    if (!reader.file.IsOpen())
        return -1;

    for (const auto& entry : reader.entries) {
        if (entry.uncompressed_size < 0x70) {
            LOG_ERROR(HW, "size too small {}", entry.uncompressed_size);
            continue;
        }

        std::vector<std::string> elems = FileUtil::SplitPathComponents(entry.name);
        if (elems.size() != 2) {
            LOG_ERROR(HW, "bad dir structure {}", entry.name);
            continue;
        }

        std::string id = elems[0];
        std::string filename = elems[1];

        if (filename[0] != '_' || filename.length() != 12) {
            LOG_ERROR(HW, "bad filename {}", filename);
            continue;
        }

        std::string inboxPath = FileUtil::GetUserPath(FileUtil::UserPath::NANDDir) + DIR_SEP +
                                "data" + DIR_SEP + "00000000000000000000000000000000" + DIR_SEP +
                                "sysdata" + DIR_SEP + "00010026" + DIR_SEP + "00000000" + DIR_SEP +
                                "CEC" + DIR_SEP + id + DIR_SEP + "InBox___";

        if (!FileUtil::IsDirectory(inboxPath)) {
            LOG_ERROR(HW, "no inbox {}", inboxPath);
            continue;
        }

        std::string boxInfoPath = inboxPath + DIR_SEP + "BoxInfo_____";

        if (!FileUtil::Exists(boxInfoPath)) {
            LOG_ERROR(HW, "no boxInfo {}", boxInfoPath);
            continue;
        }

        struct Service::CECD::Module::CecBoxInfoHeader boxInfo;
        FileUtil::IOFile bfile(boxInfoPath, "rb+");
        bfile.ReadBytes(&boxInfo, sizeof(Service::CECD::Module::CecBoxInfoHeader));

        if (entry.uncompressed_size > boxInfo.max_message_size) {
            bfile.Close();
            LOG_ERROR(HW, "message too big {} / {}", entry.uncompressed_size,
                      boxInfo.max_message_size);
            continue;
        }

        const std::string ext_inbox_path{
            fmt::format("{}/zippass/inboxes/{}/",
                        FileUtil::GetUserPath(FileUtil::UserPath::UserDir), id)};
        bool ext_inbox = false;

        if (boxInfo.message_num >= boxInfo.max_message_num) {
            FileUtil::CreateFullPath(ext_inbox_path);
            ext_inbox = true;
            LOG_ERROR(HW, "streetpass inbox full {} / {} -> external inbox", boxInfo.message_num,
                      boxInfo.max_message_num);

            FileUtil::FSTEntry data_dir;
            std::vector<FileUtil::FSTEntry> files;
            FileUtil::ScanDirectoryTree(ext_inbox_path, data_dir, 2048);
            FileUtil::GetAllFilesFromNestedEntries(data_dir, files);

            if (files.size() > 99) {
                bfile.Close();
                LOG_ERROR(Service_FS, "external inbox is full");
                continue;
            }
        }

        if (entry.uncompressed_size > 0x4000000) {
            LOG_ERROR(HW, "entry too big {}", entry.uncompressed_size);
            continue;
        }

        std::vector<u8> buff;
        if (!reader.Read(entry, buff)) {
            LOG_ERROR(HW, "failed to read zip entry {}", entry.name);
            bfile.Close();
            continue;
        }

        Service::CECD::Module::CecMessageHeader* messHead =
            reinterpret_cast<Service::CECD::Module::CecMessageHeader*>(buff.data());

        std::string b64_messageId = "_" + Service::CECD::Module::EncodeBase64(messHead->message_id);

        std::string sTitleId;
        unsigned char* bTitleId = reinterpret_cast<unsigned char*>(&messHead->title_id);

        for (int i = 3; i >= 0; i--) {
            sTitleId += fmt::format("{:02x}", bTitleId[i]);
        }

        if (messHead->magic != 0x6060 || messHead->message_size != entry.uncompressed_size ||
            sTitleId != id || b64_messageId != filename) {
            LOG_ERROR(HW, "bad message header {} {} {} {}", messHead->magic, messHead->message_size,
                      sTitleId, b64_messageId);

            bfile.Close();
            continue;
        }

        auto initTime = SharedPage::GetInitTime(0);
        std::chrono::system_clock::time_point tp(initTime);
        std::time_t time = std::chrono::system_clock::to_time_t(tp);
        std::tm tm = *std::localtime(&time);

        messHead->send_time.year = tm.tm_year + 1900;
        messHead->send_time.month = tm.tm_mon + 1;
        messHead->send_time.day = tm.tm_mday;
        messHead->send_time.hour = tm.tm_hour;
        messHead->send_time.minute = tm.tm_min;
        messHead->send_time.second = tm.tm_sec;
        messHead->send_time.millisecond = 1;
        messHead->send_time.microsecond = 1;
        messHead->send_time.padding = 1;

        messHead->recv_time = messHead->send_time;

        CryptoPP::AutoSeededRandomPool rng;
        rng.GenerateBlock(messHead->message_id.data(), messHead->message_id.size());
        filename = "_" + Service::CECD::Module::EncodeBase64(messHead->message_id);

        std::string out_path = inboxPath + DIR_SEP + filename;

        if (ext_inbox) {
            out_path = ext_inbox_path + filename;
        }

        FileUtil::IOFile dfile(out_path, "wb");

        int written = static_cast<int>(dfile.WriteBytes(buff.data(), buff.size()));

        dfile.Close();

        if (written != static_cast<int>(buff.size())) {
            LOG_ERROR(HW, "written != st.size {} / {}", written, buff.size());

            bfile.Close();

            ret = -1;
            break;
        }

        if (!ext_inbox) {
            boxInfo.message_num++;
            boxInfo.box_info_size += 0x70;
            boxInfo.box_size += static_cast<u32>(buff.size());

            bfile.Seek(0, SEEK_SET);
            bfile.WriteBytes(&boxInfo, sizeof(Service::CECD::Module::CecBoxInfoHeader));

            bfile.Seek(0, SEEK_END);
            bfile.WriteBytes(buff.data(), 0x70);
        }

        bfile.Close();

        ret++;
    }

    return ret;
}

int importQueuedZipPass() {
    LOG_INFO(Frontend, "importQueuedZipPass");

    int chck = zipPassChecks();
    if (chck)
        return chck;

    FileUtil::FSTEntry data_dir;
    std::vector<FileUtil::FSTEntry> files;
    const std::string inboxes_path{
        fmt::format("{}/zippass/inboxes", FileUtil::GetUserPath(FileUtil::UserPath::UserDir))};
    const std::string queue_path{
        fmt::format("{}/zippass/queue", FileUtil::GetUserPath(FileUtil::UserPath::UserDir))};
    const std::string history_path{
        fmt::format("{}/zippass/history/", FileUtil::GetUserPath(FileUtil::UserPath::UserDir))};

    if (!FileUtil::CreateFullPath(history_path)) {
        LOG_ERROR(Service_FS, "Failed to create history_path");
        return -10;
    }

    FileUtil::ScanDirectoryTree(inboxes_path, data_dir, 2048);
    FileUtil::GetAllFilesFromNestedEntries(data_dir, files);

    for (size_t i = 0; i < files.size(); i++) {
        std::string file = files[i].physicalName;
        auto filepath_elems = FileUtil::SplitPathComponents(file);

        if (filepath_elems.size() > 1) {
            std::string filename = filepath_elems.back();
            filepath_elems.pop_back();
            std::string folder = filepath_elems.back();

            LOG_ERROR(Service_FS, "Import from ext inbox {} / {}", folder, filename);

            std::string inbox = FileUtil::GetUserPath(FileUtil::UserPath::NANDDir) + DIR_SEP +
                                "data" + DIR_SEP + "00000000000000000000000000000000" + DIR_SEP +
                                "sysdata" + DIR_SEP + "00010026" + DIR_SEP + "00000000" + DIR_SEP +
                                "CEC" + DIR_SEP + folder + DIR_SEP + "InBox___";

            std::string boxInfoPath = inbox + DIR_SEP + "BoxInfo_____";

            if (FileUtil::IsDirectory(inbox) && FileUtil::Exists(boxInfoPath)) {
                struct Service::CECD::Module::CecBoxInfoHeader boxInfo;
                FileUtil::IOFile bfile(boxInfoPath, "rb+");
                bfile.ReadBytes(&boxInfo, sizeof(Service::CECD::Module::CecBoxInfoHeader));

                if (boxInfo.message_num >= boxInfo.max_message_num) {
                    LOG_ERROR(Service_FS, "streetpass inbox full {} / {}", boxInfo.message_num,
                              boxInfo.max_message_num);
                    bfile.Close();
                    continue;
                }

                std::vector<u8> buff(0x70);
                FileUtil::IOFile spfile(file, "rb");

                spfile.ReadBytes(buff.data(), buff.size());
                spfile.Close();

                u64 size = FileUtil::GetSize(file);
                FileUtil::Rename(file, inbox + DIR_SEP + filename);

                boxInfo.message_num++;
                boxInfo.box_info_size += 0x70;
                boxInfo.box_size += static_cast<u32>(size);

                bfile.Seek(0, SEEK_SET);
                bfile.WriteBytes(&boxInfo, sizeof(Service::CECD::Module::CecBoxInfoHeader));

                bfile.Seek(0, SEEK_END);
                bfile.WriteBytes(buff.data(), 0x70);

                bfile.Close();
            }
        }

        FileUtil::Delete(file);
    }

    data_dir.children.clear();
    files.clear();
    FileUtil::ScanDirectoryTree(queue_path, data_dir, 2048);
    FileUtil::GetAllFilesFromNestedEntries(data_dir, files);

    for (size_t i = 0; i < files.size(); i++) {
        std::string file = files[i].physicalName;

        if (file.ends_with(".pass.zip")) {
            int ret = Core::importZipPass(file);

            if (ret < 0) {
                return ret;
            }

            const std::string newPath = history_path + FileUtil::SplitPathComponents(file).back();

            FileUtil::Delete(newPath);
            FileUtil::Rename(file, newPath);
        }

        FileUtil::Delete(file);
    }

    Core::trimZipPassHistory();

    return 0;
}

void trimZipPassHistory() {
    const std::string history_path{
        fmt::format("{}/zippass/history/", FileUtil::GetUserPath(FileUtil::UserPath::UserDir))};
    FileUtil::FSTEntry data_dir;
    std::vector<FileUtil::FSTEntry> files;

    FileUtil::ScanDirectoryTree(history_path, data_dir, 2048);
    FileUtil::GetAllFilesFromNestedEntries(data_dir, files);

    int toRemove = static_cast<int>(files.size()) - 100;

    if (toRemove > 0) {
        std::map<time_t, std::string> historyFiles;

        for (auto file : files) {
            historyFiles[FileUtil::GetDate(file.physicalName)] = file.physicalName;
        }

        for (auto it = historyFiles.begin(); it != historyFiles.end() && toRemove > 0; it++) {
            FileUtil::Delete(it->second);
            toRemove--;
        }
    }
}

int clearStreetPassConfig() {
    const auto callback = [](u64* num_entries_out, const std::string& directory,
                             const std::string& virtual_name) -> bool {
        const std::string physical_name = directory + DIR_SEP + virtual_name;
        if (FileUtil::IsDirectory(physical_name)) {
            LOG_INFO(Frontend, "streetpass directory to delete {}", physical_name);
            FileUtil::DeleteDirRecursively(physical_name);
        }
        return true;
    };

    const std::string dir = FileUtil::GetUserPath(FileUtil::UserPath::NANDDir) + DIR_SEP + "data" +
                            DIR_SEP + "00000000000000000000000000000000" + DIR_SEP + "sysdata" +
                            DIR_SEP + "00010026" + DIR_SEP + "00000000" + DIR_SEP + "CEC";

    FileUtil::ForeachDirectoryEntry(nullptr, dir, callback);

    return 0;
}

} // namespace Core
