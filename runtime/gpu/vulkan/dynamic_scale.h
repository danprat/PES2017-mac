#pragma once
// PES17_DYNAMIC_SCALE: the scene's render scale, moved while the match runs.
//
// The match is heat-bound (docs/performance.md): at a skin temperature of 47-48 C
// the GPU is held to 305-400 MHz and the same frame costs half as much again.
// A scale chosen for a cool phone is wrong ten minutes in. This holds the passes'
// GPU time under a share of the frame and lowers the scale when it is over, and
// takes the phone's own thermal status (PowerManager's THERMAL_STATUS_*) as a
// ceiling, so it backs off before the status reaches CRITICAL rather than after.
//
// It is the policy only: no Vulkan, no clock, nothing it cannot be tested without.
// The renderer feeds it the GPU time of each world frame and, at a frame boundary,
// asks whether the scale moved (renderer_frame.cpp).
//
// The scale is counted in sixteenths of 1280x720, as the renderer rounds it:
// 16 is 1280x720, 12 is 960x540, 8 is 640x360.
#include <algorithm>
#include <cstdint>

namespace vk::dynscale
{
    class Controller
    {
    public:
        static constexpr int kWindow = 90;           // world frames a decision is made from
        static constexpr int kCooldownWindows = 2;   // ignored after a change: the images are new
        static constexpr int kUpWindows = 3;         // calm windows before a step up

        // `ceiling` is the scale the player chose, `floor` the least it may fall to,
        // `budgetMs` the passes' share of a frame (a frame period, less what is not
        // GPU pass time).
        void Configure(int ceiling, int floor, double budgetMs)
        {
            floor_ = std::clamp(floor, 4, 16);
            ceiling_ = std::clamp(ceiling, floor_, 16);
            budget_ = std::max(budgetMs, 1.0);
            current_ = ceiling_;
            ResetWindow();
            calm_ = 0;
            cooldown_ = 0;
            recover_ = 0;
        }

        // The two rules are separate choices: `heat` takes the picture down as the phone's thermal
        // status rises (and back as it falls), `load` moves it with the GPU time the passes take.
        // Both off leaves the scale where the player put it.
        void SetRules(bool heat, bool load) { heat_ = heat; load_ = load; }
        bool Heat() const { return heat_; }
        bool Load() const { return load_; }

        // android.os.PowerManager.THERMAL_STATUS_*: 0 none, 1 light, 2 moderate,
        // 3 severe, 4 critical, 5 emergency, 6 shutdown.
        void SetThermal(int status) { thermal_ = std::clamp(status, 0, 6); }

        // The cap the phone's own heat allows, as a share of the room between the player's
        // scale and the floor: nothing below MODERATE, a quarter at MODERATE, half at SEVERE and
        // all of it from CRITICAL. (A measured run: the phone sat at SEVERE from the first minute
        // of a match, and a table that took the picture to the floor there held it at the floor
        // for the whole match.) It is a ceiling, not a target: a GPU with no room still goes lower.
        int ThermalCeiling() const
        {
            if (!heat_) return ceiling_;
            static constexpr int kQuarters[7] = { 0, 0, 1, 2, 4, 4, 4 };
            const int range = ceiling_ - floor_;
            return ceiling_ - (range * kQuarters[thermal_] + 3) / 4;
        }

        int Current() const { return current_; }
        int Ceiling() const { return ceiling_; }
        int Floor() const { return floor_; }
        double Budget() const { return budget_; }

        // Every frame presented. The heat rule: down at once when the phone's status calls for
        // it, and, when the load rule is not there to bring it back, up a step every few seconds
        // the status allows. Returns true when the scale changed.
        bool Frame()
        {
            const int hot = ThermalCeiling();
            if (current_ > hot)
            {
                Move(hot);
                recover_ = 0;
                return true;
            }
            if (!heat_ || load_ || current_ >= hot) { recover_ = 0; return false; }
            if (++recover_ < 2 * kWindow) return false;
            recover_ = 0;
            Move(current_ + 1);
            return true;
        }

        // One frame's pass time in milliseconds, from a frame that drew the world: the load rule.
        // Returns true when the scale changed; read it with Current().
        bool Note(double ms)
        {
            if (!load_) return false;
            bool changed = false;
            // Heat first, and at once: waiting a window for a phone that has gone
            // SEVERE is waiting for CRITICAL.
            const int hot = ThermalCeiling();
            if (current_ > hot)
            {
                Move(hot);
                changed = true;
            }
            sum_ += ms;
            if (++frames_ < kWindow) return changed;
            const double average = sum_ / frames_;
            ResetWindow();
            if (cooldown_ > 0) { cooldown_--; return changed; }

            if (average > budget_)
            {
                // Over: the cost follows the pixels, which follow the square of the
                // scale, so the scale that fits is the current one times the root of
                // the budget's share of the average. At least one step, at most three.
                calm_ = 0;
                if (current_ <= floor_) return changed;       // nothing left to give
                int target = current_;
                while (target > floor_ && Cost(average, target, current_) > budget_ * 0.92) target--;
                target = std::clamp(target, std::max(floor_, current_ - 3), current_ - 1);
                Move(target);
                return true;
            }

            // Room to spare, and room enough for the next step up to still fit.
            const int up = std::min(current_ + 1, std::min(ceiling_, ThermalCeiling()));
            if (up > current_ && average < budget_ * 0.65 && Cost(average, up, current_) < budget_ * 0.85)
            {
                if (++calm_ >= kUpWindows) { Move(up); changed = true; }
            }
            else calm_ = 0;
            return changed;
        }

    private:
        // What `ms` at scale `from` becomes at scale `to`.
        static double Cost(double ms, int to, int from)
        {
            const double r = double(to) / double(from);
            return ms * r * r;
        }

        void Move(int to)
        {
            current_ = std::clamp(to, floor_, ceiling_);
            cooldown_ = kCooldownWindows;
            calm_ = 0;
            ResetWindow();
        }

        void ResetWindow() { sum_ = 0; frames_ = 0; }

        bool heat_ = true, load_ = true;
        int recover_ = 0;
        int floor_ = 8, ceiling_ = 12, current_ = 12;
        double budget_ = 13.0;
        int thermal_ = 0;
        double sum_ = 0;
        int frames_ = 0, calm_ = 0, cooldown_ = 0;
    };
}
