#include "Logger.hpp"

#include <chrono>
#include <ctime>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <mutex>
#include <cstdlib>
#include <sstream>

namespace Logger
{
namespace
{
std::mutex s_mutex;
std::ofstream s_file;
bool s_initialized = false;

const char* LevelTag(Level level)
{
    switch (level)
    {
    case Level::Debug:
        return "DEBUG";
    case Level::Info:
        return "INFO";
    case Level::Warn:
        return "WARN";
    case Level::Error:
        return "ERROR";
    default:
        return "INFO";
    }
}

std::string Timestamp()
{
    const auto now = std::chrono::system_clock::now();
    const auto tt = std::chrono::system_clock::to_time_t(now);
    std::tm tm{};
#if defined(_WIN32) || defined(_WIN64)
    localtime_s(&tm, &tt);
#else
    localtime_r(&tt, &tm);
#endif
    std::ostringstream oss;
    oss << std::put_time(&tm, "%Y-%m-%d %H:%M:%S");
    return oss.str();
}
}

void Initialize()
{
    std::scoped_lock _(s_mutex);
    if (s_initialized)
    {
        return;
    }

    if (const char* filePath = std::getenv("METALFX_LOG_FILE"); filePath && filePath[0] != '\0')
    {
        s_file.open(filePath, std::ios::out | std::ios::app);
    }
    else
    {
        // The game runs with its folder as the working directory; one log per session, next to RED4ext's.
        s_file.open("red4ext/logs/metalfxdenoiser.log", std::ios::out | std::ios::trunc);
    }
    s_initialized = true;
}

void Shutdown()
{
    std::scoped_lock _(s_mutex);
    if (s_file.is_open())
    {
        s_file.flush();
        s_file.close();
    }
    s_initialized = false;
}

void Log(Level level, std::string_view message)
{
    Initialize(); // no-op once initialized; takes the lock itself
    std::scoped_lock _(s_mutex);

    const auto line = "[" + Timestamp() + "] [MetalFXDenoiser] [" + std::string(LevelTag(level)) + "] " +
                      std::string(message);

    std::cerr << line << std::endl;
    if (s_file.is_open())
    {
        s_file << line << '\n';
        s_file.flush();
    }
}

void Debug(std::string_view message)
{
    Log(Level::Debug, message);
}

void Info(std::string_view message)
{
    Log(Level::Info, message);
}

void Warn(std::string_view message)
{
    Log(Level::Warn, message);
}

void Error(std::string_view message)
{
    Log(Level::Error, message);
}
} // namespace Logger
