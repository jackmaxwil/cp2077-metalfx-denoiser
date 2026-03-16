#pragma once

#include <string_view>

namespace Logger
{
enum class Level
{
    Debug,
    Info,
    Warn,
    Error
};

void Initialize();
void Shutdown();

void Log(Level level, std::string_view message);
void Debug(std::string_view message);
void Info(std::string_view message);
void Warn(std::string_view message);
void Error(std::string_view message);
} // namespace Logger
